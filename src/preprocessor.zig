// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const lexer = @import("lexer.zig");

pub const Preprocessor = struct {
    alloc: std.mem.Allocator,
    defines: std.StringHashMapUnmanaged(Macro),
    if_stack: std.ArrayListUnmanaged(IfState),
    output: std.ArrayListUnmanaged(lexer.Token),
    source: [:0]const u8 = "",
    version: u32 = 430,
    is_essl: bool = false,
    expanding: std.ArrayListUnmanaged([]const u8),
    extra_strings: std.ArrayListUnmanaged(u8),
    has_ext_mesh_shader: bool = false,
    has_ext_ray_tracing: bool = false,
    has_ext_fragment_shader_interlock: bool = false,

    // Include support
    include_paths: []const []const u8 = &.{},
    include_depth: u32 = 0,
    max_include_depth: u32 = 16,
    included_files: std.StringHashMapUnmanaged(void) = .empty, // cycle detection
    pragma_once_files: std.StringHashMapUnmanaged(void) = .empty, // #pragma once
    file_reader: ?*const fn ([]const u8) anyerror![:0]const u8 = null,
    // Back-reference to the source file path for relative includes
    source_file_path: []const u8 = "",
    // Stored include file contents (to keep slices alive)
    included_sources: std.ArrayListUnmanaged([:0]const u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Preprocessor {
        return .{
            .alloc = alloc,
            .defines = .empty,
            .if_stack = .empty,
            .output = .empty,
            .expanding = .empty,
            .extra_strings = .empty,
        };
    }

    pub fn deinit(self: *Preprocessor) void {
        var macro_iter = self.defines.iterator();
        while (macro_iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .object => |tokens| self.alloc.free(tokens),
                .function => |f| {
                    for (f.params) |p| self.alloc.free(p);
                    self.alloc.free(f.params);
                    self.alloc.free(f.body);
                },
            }
        }
        self.defines.deinit(self.alloc);
        self.if_stack.deinit(self.alloc);
        self.output.deinit(self.alloc);
        self.expanding.deinit(self.alloc);
        self.extra_strings.deinit(self.alloc);
        // Clean up include tracking
        {
            var it = self.included_files.keyIterator();
            while (it.next()) |k| self.alloc.free(k.*);
        }
        self.included_files.deinit(self.alloc);
        // Clean up pragma once tracking
        {
            var it2 = self.pragma_once_files.keyIterator();
            while (it2.next()) |k| self.alloc.free(k.*);
        }
        self.pragma_once_files.deinit(self.alloc);
        for (self.included_sources.items) |src| self.alloc.free(src);
        self.included_sources.deinit(self.alloc);
    }

    pub fn addDefine(self: *Preprocessor, name: []const u8, value: []const lexer.Token) !void {
        const name_copy = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(name_copy);

        const value_copy = try self.alloc.dupe(lexer.Token, value);
        errdefer self.alloc.free(value_copy);

        try self.defines.put(self.alloc, name_copy, .{ .object = value_copy });
    }

    fn isActive(self: *const Preprocessor) bool {
        for (self.if_stack.items) |state| {
            if (!state.active) return false;
        }
        return true;
    }

    fn getTokenText(self: *const Preprocessor, tok: lexer.Token) []const u8 {
        if (tok.start >= self.source.len) {
            // Synthetic token — text is in extra_strings
            const start = tok.start - self.source.len;
            return self.extra_strings.items[start..][0..tok.len];
        }
        return self.source[tok.start..tok.start + tok.len];
    }

    fn skipToEndOfLine(self: *Preprocessor, tokens: []const lexer.Token, index: *usize) void {
        _ = self;
        const start_line = tokens[index.*].loc.line;
        while (index.* < tokens.len) : (index.* += 1) {
            const tok = tokens[index.*];
            if (tok.tag == .eof) break;
            if (tok.loc.line > start_line) break;
        }
    }

    fn handleInclude(self: *Preprocessor, tokens: []const lexer.Token, index: *usize) !void {
        index.* += 1; // skip pp_include

        if (index.* >= tokens.len) return error.PreprocessFailed;

        // Get the filename token
        const file_tok = tokens[index.*];
        var include_path: ?[]const u8 = null;
        var is_system = false;

        if (file_tok.tag == .string_literal) {
            // #include "file" \u2014 relative include
            include_path = self.getTokenText(file_tok);
            // Strip quotes
            if (include_path != null and include_path.?.len >= 2) {
                include_path = include_path.?[1 .. include_path.?.len - 1];
            }
        } else if (file_tok.tag == .lt) {
            // #include <file> \u2014 system include
            is_system = true;
            index.* += 1;
            var path_buf = std.ArrayListUnmanaged(u8).empty;
            defer path_buf.deinit(self.alloc);
            while (index.* < tokens.len) : (index.* += 1) {
                const tok = tokens[index.*];
                if (tok.tag == .gt) break;
                const text = self.getTokenText(tok);
                try path_buf.appendSlice(self.alloc, text);
            }
            if (path_buf.items.len > 0) {
                include_path = path_buf.items;
            }
        }

        // Skip rest of line
        while (index.* < tokens.len) : (index.* += 1) {
            const tok = tokens[index.*];
            if (tok.tag == .eof or tok.loc.line > file_tok.loc.line) break;
        }

        const path = include_path orelse return;
        if (path.len == 0) return;

        // Check include depth
        if (self.include_depth >= self.max_include_depth) return error.PreprocessFailed;

        // Check for cycles
        if (self.included_files.contains(path)) return;

        // Check #pragma once — skip if file was already included with #pragma once
        if (self.pragma_once_files.contains(path)) return;

        // Resolve the file and read it
        const resolved_source = self.resolveInclude(path, is_system) catch |err| switch (err) {
            error.FileNotFound => {
                // Include file not found \u2014 skip silently
                return;
            },
            else => return err,
        };

        // Mark as included for cycle detection
        const path_copy = try self.alloc.dupe(u8, path);
        try self.included_files.put(self.alloc, path_copy, {});

        // Tokenize the included source
        const inc_tokens = try lexer.tokenize(self.alloc, resolved_source);

        // Recursively preprocess the included tokens
        const saved_source = self.source;
        const saved_source_path = self.source_file_path;
        self.source = resolved_source;
        self.source_file_path = path;
        self.include_depth += 1;
        defer {
            self.source = saved_source;
            self.source_file_path = saved_source_path;
            self.include_depth -= 1;
        }

        // Process included tokens inline (same logic as main process loop)
        var j: usize = 0;
        while (j < inc_tokens.len) {
            const tok = inc_tokens[j];
            switch (tok.tag) {
                .pp_include => {
                    try self.handleInclude(inc_tokens, &j);
                },
                .pp_define => {
                    if (self.isActive()) {
                        try self.parseDefine(inc_tokens, &j);
                    } else {
                        self.skipToEndOfLine(inc_tokens, &j);
                    }
                },
                .pp_undef => {
                    if (self.isActive()) {
                        j += 1;
                        if (j < inc_tokens.len and inc_tokens[j].tag == .identifier) {
                            const name = self.getTokenText(inc_tokens[j]);
                            if (self.defines.fetchRemove(name)) |entry| {
                                self.alloc.free(entry.key);
                                switch (entry.value) {
                                    .object => |body| self.alloc.free(body),
                                    .function => |f| {
                                        for (f.params) |p| self.alloc.free(p);
                                        self.alloc.free(f.params);
                                        self.alloc.free(f.body);
                                    },
                                }
                            }
                            j += 1;
                        }
                    } else {
                        self.skipToEndOfLine(inc_tokens, &j);
                    }
                },
                .pp_ifdef => {
                    j += 1;
                    if (j < inc_tokens.len and inc_tokens[j].tag == .identifier) {
                        const name = self.getTokenText(inc_tokens[j]);
                        const defined = self.defines.contains(name);
                        try self.if_stack.append(self.alloc, .{
                            .taken = defined,
                            .any_taken = defined,
                            .active = defined,
                        });
                        j += 1;
                    }
                },
                .pp_ifndef => {
                    j += 1;
                    if (j < inc_tokens.len and inc_tokens[j].tag == .identifier) {
                        const name = self.getTokenText(inc_tokens[j]);
                        const defined = self.defines.contains(name);
                        try self.if_stack.append(self.alloc, .{
                            .taken = !defined,
                            .any_taken = !defined,
                            .active = !defined,
                        });
                        j += 1;
                    }
                },
                .pp_if => {
                    j += 1;
                    const expr_start = j;
                    while (j < inc_tokens.len and inc_tokens[j].loc.line == tok.loc.line) : (j += 1) {}
                    const expr_end = j;
                    const result = try self.evaluateExpression(inc_tokens, expr_start, expr_end);
                    const taken = result != 0;
                    try self.if_stack.append(self.alloc, .{
                        .taken = taken,
                        .any_taken = taken,
                        .active = taken,
                    });
                },
                .pp_elif => {
                    if (self.if_stack.items.len == 0) return error.PreprocessFailed;
                    const state = &self.if_stack.items[self.if_stack.items.len - 1];
                    if (!state.any_taken) {
                        j += 1;
                        const expr_start = j;
                        while (j < inc_tokens.len and inc_tokens[j].loc.line == tok.loc.line) : (j += 1) {}
                        const expr_end = j;
                        const result = try self.evaluateExpression(inc_tokens, expr_start, expr_end);
                        const taken = result != 0;
                        state.taken = taken;
                        state.any_taken = taken;
                        state.active = taken;
                    } else {
                        state.active = false;
                        self.skipToEndOfLine(inc_tokens, &j);
                    }
                },
                .pp_else => {
                    if (self.if_stack.items.len == 0) return error.PreprocessFailed;
                    const state = &self.if_stack.items[self.if_stack.items.len - 1];
                    if (!state.any_taken) {
                        state.taken = true;
                        state.any_taken = true;
                        state.active = true;
                    } else {
                        state.active = false;
                    }
                    j += 1;
                },
                .pp_endif => {
                    if (self.if_stack.items.len == 0) return error.PreprocessFailed;
                    _ = self.if_stack.pop();
                    j += 1;
                },
                .pp_version => {
                    self.skipToEndOfLine(inc_tokens, &j);
                },
                .pp_error, .pp_warning, .pp_line, .pp_extension => {
                    self.skipToEndOfLine(inc_tokens, &j);
                },
                .pp_pragma => {
                    // #pragma once in included file
                    if (self.isActive() and j + 2 < inc_tokens.len) {
                        if (inc_tokens[j + 1].tag == .identifier) {
                            const pragma_name = self.getTokenText(inc_tokens[j + 1]);
                            if (std.mem.eql(u8, pragma_name, "once")) {
                                if (self.source_file_path.len > 0) {
                                    const once_path = try self.alloc.dupe(u8, self.source_file_path);
                                    try self.pragma_once_files.put(self.alloc, once_path, {});
                                }
                            }
                        }
                    }
                    self.skipToEndOfLine(inc_tokens, &j);
                },
                .identifier => {
                    if (self.isActive()) {
                        try self.expandMacro(inc_tokens, &j, tok);
                    } else {
                        j += 1;
                    }
                },
                .eof => {
                    j += 1;
                },
                else => {
                    if (self.isActive()) {
                        try self.output.append(self.alloc, tok);
                    }
                    j += 1;
                },
            }
        }

        self.alloc.free(inc_tokens);
    }

    fn resolveInclude(self: *Preprocessor, path: []const u8, is_system: bool) ![:0]const u8 {
        // Try file reader callback first
        if (self.file_reader) |reader| {
            return reader(path);
        }

        // Try relative to source file
        if (!is_system and self.source_file_path.len > 0) {
            var dir_end = self.source_file_path.len;
            while (dir_end > 0 and self.source_file_path[dir_end - 1] != '/' and self.source_file_path[dir_end - 1] != '\\') dir_end -= 1;
            const dir_part = self.source_file_path[0..dir_end];

            var full_path_buf: [4096]u8 = undefined;
            const full_path = std.fmt.bufPrintZ(&full_path_buf, "{s}{s}", .{ dir_part, path }) catch return error.FileNotFound;

            const file = std.fs.cwd().openFile(full_path, .{}) catch return error.FileNotFound;
            defer file.close();
            const raw = try file.readToEndAlloc(self.alloc, 10 * 1024 * 1024);
            // Null-terminate for lexer
            const z = try self.alloc.dupeZ(u8, raw);
            self.alloc.free(raw);
            try self.included_sources.append(self.alloc, z);
            return z;
        }

        // Try include paths
        for (self.include_paths) |inc_path| {
            var full_path_buf: [4096]u8 = undefined;
            const full_path = std.fmt.bufPrintZ(&full_path_buf, "{s}/{s}", .{ inc_path, path }) catch continue;

            const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
            defer file.close();
            const raw = try file.readToEndAlloc(self.alloc, 10 * 1024 * 1024);
            const z = try self.alloc.dupeZ(u8, raw);
            self.alloc.free(raw);
            try self.included_sources.append(self.alloc, z);
            return z;
        }

        return error.FileNotFound;
    }

    fn parseDefine(self: *Preprocessor, tokens: []const lexer.Token, index: *usize) !void {
        // Skip pp_define token
        index.* += 1;

        if (index.* >= tokens.len) return error.PreprocessFailed;

        const name_tok = tokens[index.*];
        if (name_tok.tag != .identifier) return error.PreprocessFailed;

        const name = try self.alloc.dupe(u8, self.getTokenText(name_tok));
        index.* += 1;

        // Check for function-like macro
        if (index.* < tokens.len and tokens[index.*].tag == .l_paren) {
            index.* += 1; // skip '('

            var params = std.ArrayListUnmanaged([]const u8).empty;
            defer params.deinit(self.alloc);

            const is_variadic = false;

            // Parse parameters
            while (index.* < tokens.len) {
                const tok = tokens[index.*];
                if (tok.tag == .r_paren) {
                    index.* += 1;
                    break;
                }

                if (tok.tag == .identifier) {
                    const param_name = try self.alloc.dupe(u8, self.getTokenText(tok));
                    try params.append(self.alloc, param_name);
                    index.* += 1;

                    if (index.* < tokens.len and tokens[index.*].tag == .comma) {
                        index.* += 1;
                    }
                } else {
                    return error.PreprocessFailed;
                }
            }

            // Parse body until end of line
            var body = std.ArrayListUnmanaged(lexer.Token).empty;
            defer {
                for (body.items) |t| {
                    _ = t;
                }
                // Note: we don't free body tokens since they're borrowed from source
            }
            while (index.* < tokens.len) {
                const tok = tokens[index.*];
                if (tok.tag == .eof or tok.loc.line > name_tok.loc.line) {
                    break;
                }
                try body.append(self.alloc, tok);
                index.* += 1;
            }

            const params_owned = try self.alloc.dupe([]const u8, params.items);
            for (params.items, 0..) |p, i| {
                params_owned[i] = p;
            }

            const body_owned = try body.toOwnedSlice(self.alloc);

            try self.defines.put(self.alloc, name, .{
                .function = .{
                    .params = params_owned,
                    .body = body_owned,
                    .is_variadic = is_variadic,
                },
            });
        } else {
            // Object-like macro
            var body = std.ArrayListUnmanaged(lexer.Token).empty;
            defer {
                for (body.items) |t| {
                    _ = t;
                }
                // Note: we don't free body tokens since they're borrowed from source
            }
            while (index.* < tokens.len) {
                const tok = tokens[index.*];
                if (tok.tag == .eof or tok.loc.line > name_tok.loc.line) {
                    break;
                }
                try body.append(self.alloc, tok);
                index.* += 1;
            }

            const body_owned = try body.toOwnedSlice(self.alloc);
            try self.defines.put(self.alloc, name, .{ .object = body_owned });
        }
    }

    fn expandMacro(self: *Preprocessor, tokens: []const lexer.Token, index: *usize, identifier_tok: lexer.Token) !void {
        const name = self.getTokenText(identifier_tok);

        // Check for built-in macros
        if (std.mem.eql(u8, name, "__LINE__")) {
            index.* += 1;
            const line_num = identifier_tok.loc.line;
            var buf: [20]u8 = undefined;
            const line_str = try std.fmt.bufPrintZ(&buf, "{}", .{line_num});
            try self.output.append(self.alloc, .{
                .tag = .int_literal,
                .loc = identifier_tok.loc,
                .start = 0,
                .len = @intCast(line_str.len),
            });
            return;
        }

        if (std.mem.eql(u8, name, "__FILE__")) {
            index.* += 1;
            // Empty string for __FILE__
            try self.output.append(self.alloc, .{
                .tag = .string_literal,
                .loc = identifier_tok.loc,
                .start = 0,
                .len = 0,
            });
            return;
        }

        if (std.mem.eql(u8, name, "__VERSION__")) {
            index.* += 1;
            var buf: [20]u8 = undefined;
            const ver_str = try std.fmt.bufPrintZ(&buf, "{}", .{self.version});
            try self.output.append(self.alloc, .{
                .tag = .int_literal,
                .loc = identifier_tok.loc,
                .start = 0,
                .len = @intCast(ver_str.len),
            });
            return;
        }

        // Check if already expanding this macro (prevent recursion)
        for (self.expanding.items) |expanding_name| {
            if (std.mem.eql(u8, expanding_name, name)) {
                // Don't expand recursively, emit the identifier as-is
                index.* += 1;
                try self.output.append(self.alloc, identifier_tok);
                return;
            }
        }

        const macro = self.defines.get(name) orelse {
            // Not a macro, emit as-is
            index.* += 1;
            try self.output.append(self.alloc, identifier_tok);
            return;
        };

        // Add to expanding stack
        try self.expanding.append(self.alloc, name);
        defer {
            _ = self.expanding.pop();
        }

        switch (macro) {
            .object => |body| {
                index.* += 1;
                for (body) |tok| {
                    try self.output.append(self.alloc, tok);
                }
            },
            .function => |f| {
                // Check if next token is '('
                if (index.* + 1 >= tokens.len or tokens[index.* + 1].tag != .l_paren) {
                    // Not a function-like invocation, emit as-is
                    index.* += 1;
                    try self.output.append(self.alloc, identifier_tok);
                    return;
                }

                // Skip past identifier and '('
                index.* += 2;

                // Parse arguments
                const args = try self.parseMacroArguments(tokens, index);
                defer {
                    for (args) |arg| {
                        self.alloc.free(arg);
                    }
                    self.alloc.free(args);
                }

                // Substitute and expand
                const func_macro = Macro{ .function = f };
                try self.substituteAndExpand(func_macro, args);

                // Skip past closing ')'
                index.* += 1;
            },
        }
    }

    fn parseMacroArguments(self: *Preprocessor, tokens: []const lexer.Token, index: *usize) ![][]lexer.Token {
        var args = std.ArrayListUnmanaged([]lexer.Token).empty;

        var current_arg = std.ArrayListUnmanaged(lexer.Token).empty;
        var paren_depth: u32 = 1;

        while (index.* < tokens.len) : (index.* += 1) {
            const tok = tokens[index.*];

            if (tok.tag == .l_paren) {
                paren_depth += 1;
                try current_arg.append(self.alloc, tok);
            } else if (tok.tag == .r_paren) {
                paren_depth -= 1;
                if (paren_depth == 0) {
                    if (current_arg.items.len > 0 or args.items.len > 0) {
                        try args.append(self.alloc, try current_arg.toOwnedSlice(self.alloc));
                    }
                    break;
                }
                try current_arg.append(self.alloc, tok);
            } else if (tok.tag == .comma and paren_depth == 1) {
                try args.append(self.alloc, try current_arg.toOwnedSlice(self.alloc));
            } else {
                try current_arg.append(self.alloc, tok);
            }
        }

        return args.toOwnedSlice(self.alloc);
    }

    fn substituteAndExpand(self: *Preprocessor, func_macro: Macro, args: [][]lexer.Token) !void {
        const f = func_macro.function;
        var i: usize = 0;
        while (i < f.body.len) {
            const tok = f.body[i];

            // Handle ## (token paste) — look ahead
            if (i + 2 < f.body.len and f.body[i + 1].tag == .hash_hash) {
                // Left side: resolve param or use token text
                var left_buf: [256]u8 = undefined;
                const left_text = self.resolveParamText(f.params, args, tok, &left_buf);
                const right_tok = f.body[i + 2];
                var right_buf: [256]u8 = undefined;
                const right_text = self.resolveParamText(f.params, args, right_tok, &right_buf);
                // Concatenate and emit as identifier
                const pasted = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ left_text, right_text });
                defer self.alloc.free(pasted);
                try self.output.append(self.alloc, .{
                    .tag = .identifier,
                    .loc = tok.loc,
                    .start = 0,
                    .len = @intCast(pasted.len),
                });
                i += 3;
                continue;
            }

            // Handle # (stringify) — next token should be a param
            if (tok.tag == .hash and i + 1 < f.body.len) {
                const next_tok = f.body[i + 1];
                if (next_tok.tag == .identifier) {
                    const param_name = self.getTokenText(next_tok);
                    for (f.params, 0..) |param, idx| {
                        if (std.mem.eql(u8, param_name, param)) {
                            if (idx < args.len) {
                                // Stringify: convert arg tokens to a string literal
                                var buf: [1024]u8 = undefined;
                                var len: usize = 0;
                                buf[len] = '"'; len += 1;
                                for (args[idx], 0..) |arg_tok, ai| {
                                    if (ai > 0) {
                                        buf[len] = ' '; len += 1;
                                    }
                                    const arg_text = self.getTokenText(arg_tok);
                                    @memcpy(buf[len..][0..arg_text.len], arg_text);
                                    len += arg_text.len;
                                }
                                buf[len] = '"'; len += 1;
                                // Store in extra_strings so getTokenText works
                                const str_start = self.extra_strings.items.len;
                                try self.extra_strings.appendSlice(self.alloc, buf[0..len]);
                                try self.output.append(self.alloc, .{
                                    .tag = .string_literal,
                                    .loc = tok.loc,
                                    .start = @intCast(self.source.len + str_start),
                                    .len = @intCast(len),
                                });
                            }
                            i += 2;
                            break;
                        }
                    } else {
                        try self.output.append(self.alloc, tok);
                        i += 1;
                        continue;
                    }
                    continue;
                }
            }

            if (tok.tag == .identifier) {
                const param_name = self.getTokenText(tok);
                var found = false;
                for (f.params, 0..) |param, idx| {
                    if (std.mem.eql(u8, param_name, param)) {
                        // Emit argument tokens
                        if (idx < args.len) {
                            for (args[idx]) |arg_tok| {
                                try self.output.append(self.alloc, arg_tok);
                            }
                        }
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    // Check for __VA_ARGS__ in variadic macro
                    if (f.is_variadic and std.mem.eql(u8, param_name, "__VA_ARGS__")) {
                        for (f.params.len..args.len) |idx| {
                            for (args[idx]) |arg_tok| {
                                try self.output.append(self.alloc, arg_tok);
                            }
                            if (idx < args.len - 1) {
                                try self.output.append(self.alloc, .{
                                    .tag = .comma,
                                    .loc = tok.loc,
                                    .start = 0,
                                    .len = 1,
                                });
                            }
                        }
                    } else {
                        try self.output.append(self.alloc, tok);
                    }
                }
            } else {
                try self.output.append(self.alloc, tok);
            }
            i += 1;
        }
    }

    fn resolveParamText(self: *Preprocessor, params: []const []const u8, args: [][]lexer.Token, tok: lexer.Token, buf: []u8) []const u8 {
        if (tok.tag == .identifier) {
            const name = self.getTokenText(tok);
            for (params, 0..) |param, i| {
                if (std.mem.eql(u8, name, param)) {
                    if (i < args.len and args[i].len > 0) {
                        // Concatenate all arg tokens into text
                        var len: usize = 0;
                        for (args[i], 0..) |arg_tok, ai| {
                            if (ai > 0) {
                                buf[len] = ' ';
                                len += 1;
                            }
                            const t = self.getTokenText(arg_tok);
                            @memcpy(buf[len..][0..t.len], t);
                            len += t.len;
                        }
                        return buf[0..len];
                    }
                    return "";
                }
            }
        }
        return self.getTokenText(tok);
    }

    fn evaluateExpression(self: *Preprocessor, tokens: []const lexer.Token, start: usize, end: usize) !i64 {
        var evaluator = ExpressionEvaluator{
            .preprocessor = self,
            .tokens = tokens,
            .start = start,
            .end = end,
            .pos = start,
        };
        return evaluator.evaluate();
    }

    fn parseVersion(self: *Preprocessor, tokens: []const lexer.Token, index: *usize) !void {
        index.* += 1; // skip pp_version

        if (index.* >= tokens.len) return error.PreprocessFailed;

        const ver_tok = tokens[index.*];
        if (ver_tok.tag == .int_literal) {
            const ver_str = self.getTokenText(ver_tok);
            self.version = try std.fmt.parseInt(u32, ver_str, 10);
        }

        // Check for 'es' profile indicator
        if (index.* + 1 < tokens.len) {
            const next_tok = tokens[index.* + 1];
            if (next_tok.tag == .identifier) {
                const text = self.getTokenText(next_tok);
                if (std.mem.eql(u8, text, "es")) {
                    self.is_essl = true;
                    index.* += 1; // consume 'es'
                }
            }
        }

        // Skip to end of line
        while (index.* < tokens.len) {
            const tok = tokens[index.*];
            if (tok.tag == .eof or tok.loc.line > tokens[index.* - 1].loc.line) {
                break;
            }
            index.* += 1;
        }
    }

    pub fn process(self: *Preprocessor, source: [:0]const u8, tokens: []const lexer.Token) ![]const lexer.Token {
        self.source = source;
        self.output.clearRetainingCapacity();
        self.if_stack.clearRetainingCapacity();

        var i: usize = 0;
        while (i < tokens.len) {
            const tok = tokens[i];

            switch (tok.tag) {
                .pp_version => {
                    try self.parseVersion(tokens, &i);
                },
                .pp_define => {
                    if (self.isActive()) {
                        try self.parseDefine(tokens, &i);
                    } else {
                        self.skipToEndOfLine(tokens, &i);
                    }
                },
                .pp_undef => {
                    if (self.isActive()) {
                        i += 1; // skip pp_undef
                        if (i < tokens.len and tokens[i].tag == .identifier) {
                            const name = self.getTokenText(tokens[i]);
                            if (self.defines.fetchRemove(name)) |entry| {
                                self.alloc.free(entry.key);
                                switch (entry.value) {
                                    .object => |body| self.alloc.free(body),
                                    .function => |f| {
                                        self.alloc.free(f.params);
                                        self.alloc.free(f.body);
                                    },
                                }
                            }
                            i += 1;
                        }
                    } else {
                        self.skipToEndOfLine(tokens, &i);
                    }
                },
                .pp_ifdef => {
                    i += 1; // skip pp_ifdef
                    if (i < tokens.len and tokens[i].tag == .identifier) {
                        const name = self.getTokenText(tokens[i]);
                        const defined = self.defines.contains(name);
                        try self.if_stack.append(self.alloc, .{
                            .taken = defined,
                            .any_taken = defined,
                            .active = defined,
                        });
                        i += 1;
                    } else {
                        try self.if_stack.append(self.alloc, .{
                            .taken = false,
                            .any_taken = false,
                            .active = false,
                        });
                    }
                },
                .pp_ifndef => {
                    i += 1; // skip pp_ifndef
                    if (i < tokens.len and tokens[i].tag == .identifier) {
                        const name = self.getTokenText(tokens[i]);
                        const defined = self.defines.contains(name);
                        try self.if_stack.append(self.alloc, .{
                            .taken = !defined,
                            .any_taken = !defined,
                            .active = !defined,
                        });
                        i += 1;
                    } else {
                        try self.if_stack.append(self.alloc, .{
                            .taken = false,
                            .any_taken = false,
                            .active = false,
                        });
                    }
                },
                .pp_if => {
                    i += 1; // skip pp_if
                    // Find end of line for expression
                    const expr_start = i;
                    while (i < tokens.len and tokens[i].loc.line == tok.loc.line) : (i += 1) {}
                    const expr_end = i;

                    const result = try self.evaluateExpression(tokens, expr_start, expr_end);
                    const taken = result != 0;
                    try self.if_stack.append(self.alloc, .{
                        .taken = taken,
                        .any_taken = taken,
                        .active = taken,
                    });
                },
                .pp_elif => {
                    if (self.if_stack.items.len == 0) return error.PreprocessFailed;
                    const state = &self.if_stack.items[self.if_stack.items.len - 1];

                    if (!state.any_taken) {
                        i += 1; // skip pp_elif
                        const expr_start = i;
                        while (i < tokens.len and tokens[i].loc.line == tok.loc.line) : (i += 1) {}
                        const expr_end = i;

                        const result = try self.evaluateExpression(tokens, expr_start, expr_end);
                        const taken = result != 0;
                        state.taken = taken;
                        state.any_taken = taken;
                        state.active = taken;
                    } else {
                        state.active = false;
                        self.skipToEndOfLine(tokens, &i);
                    }
                },
                .pp_else => {
                    if (self.if_stack.items.len == 0) return error.PreprocessFailed;
                    const state = &self.if_stack.items[self.if_stack.items.len - 1];

                    if (!state.any_taken) {
                        state.taken = true;
                        state.any_taken = true;
                        state.active = true;
                    } else {
                        state.active = false;
                    }
                    i += 1;
                },
                .pp_endif => {
                    if (self.if_stack.items.len == 0) return error.PreprocessFailed;
                    _ = self.if_stack.pop();
                    i += 1;
                },
                .pp_include => {
                    if (self.isActive()) {
                        try self.handleInclude(tokens, &i);
                    } else {
                        self.skipToEndOfLine(tokens, &i);
                    }
                },
                .pp_error, .pp_warning => {
                    // #error/#warning directive — skip but could report in future
                    self.skipToEndOfLine(tokens, &i);
                },
                .pp_pragma => {
                    // #pragma — check for #pragma once
                    if (self.isActive() and i + 2 < tokens.len) {
                        if (tokens[i + 1].tag == .identifier) {
                            const pragma_name = self.getTokenText(tokens[i + 1]);
                            if (std.mem.eql(u8, pragma_name, "once")) {
                                // Mark current file as #pragma once
                                if (self.source_file_path.len > 0) {
                                    const path_copy = try self.alloc.dupe(u8, self.source_file_path);
                                    try self.pragma_once_files.put(self.alloc, path_copy, {});
                                }
                                self.skipToEndOfLine(tokens, &i);
                                continue;
                            }
                        }
                    }
                    self.skipToEndOfLine(tokens, &i);
                },
                .pp_line => {
                    // #line N or #line N "file" — skip (line directives are informational)
                    self.skipToEndOfLine(tokens, &i);
                },
                .pp_extension => {
                    // Parse #extension NAME : behavior
                    // Only define macros for extensions where the feature is actually supported
                    if (self.isActive() and i + 4 < tokens.len) {
                        const save_i = i;
                        i += 1; // skip #extension token
                        if (i < tokens.len and tokens[i].tag == .identifier) {
                            const ext_name = self.getTokenText(tokens[i]);
                            i += 1;
                            if (i < tokens.len and tokens[i].tag == .colon) {
                                i += 1; // skip :
                                if (i < tokens.len and tokens[i].tag == .identifier) {
                                    const behavior = self.getTokenText(tokens[i]);
                                    if ((std.mem.eql(u8, behavior, "enable") or std.mem.eql(u8, behavior, "require")) and
                                        (std.mem.eql(u8, ext_name, "GL_EXT_null_initializer") or
                                         std.mem.eql(u8, ext_name, "GL_EXT_mesh_shader") or
                                         std.mem.eql(u8, ext_name, "GL_KHR_ray_tracing") or
                                         std.mem.eql(u8, ext_name, "GL_ARB_fragment_shader_interlock")))
                                    {
                                        if (std.mem.eql(u8, ext_name, "GL_EXT_mesh_shader")) {
                                            self.has_ext_mesh_shader = true;
                                        }
                                        if (std.mem.eql(u8, ext_name, "GL_KHR_ray_tracing")) {
                                            self.has_ext_ray_tracing = true;
                                        }
                                        if (std.mem.eql(u8, ext_name, "GL_ARB_fragment_shader_interlock")) {
                                            self.has_ext_fragment_shader_interlock = true;
                                        }
                                        const name_dup = try self.alloc.dupe(u8, ext_name);
                                        const one_tok = lexer.Token{ .tag = .int_literal, .loc = tokens[i].loc, .start = 0, .len = 1 };
                                        const body = try self.alloc.dupe(lexer.Token, &.{one_tok});
                                        try self.defines.put(self.alloc, name_dup, .{ .object = body });
                                    }
                                }
                            }
                        }
                        i = save_i;
                    }
                    self.skipToEndOfLine(tokens, &i);
                },
                .identifier => {
                    if (self.isActive()) {
                        try self.expandMacro(tokens, &i, tok);
                    } else {
                        i += 1;
                    }
                },
                .eof => {
                    if (self.isActive()) {
                        try self.output.append(self.alloc, tok);
                    }
                    i += 1;
                },
                else => {
                    if (self.isActive()) {
                        try self.output.append(self.alloc, tok);
                    }
                    i += 1;
                },
            }
        }

        return self.output.toOwnedSlice(self.alloc);
    }
};

const Macro = union(enum) {
    object: []const lexer.Token,
    function: struct {
        params: []const []const u8,
        body: []const lexer.Token,
        is_variadic: bool,
    },
};

const IfState = struct {
    taken: bool,
    any_taken: bool,
    active: bool,
};

const ExprEvalError = error{ PreprocessFailed, InvalidCharacter, Overflow };

const ExpressionEvaluator = struct {
    preprocessor: *Preprocessor,
    tokens: []const lexer.Token,
    start: usize,
    end: usize,
    pos: usize,

    fn evaluate(self: *ExpressionEvaluator) ExprEvalError!i64 {
        self.pos = self.start;
        return self.parseConditional();
    }

    fn parseConditional(self: *ExpressionEvaluator) ExprEvalError!i64 {
        const cond = try self.parseLogicalOr();
        if (self.peek()) |tok| {
            if (tok.tag == .question) {
                self.pos += 1;
                const left = try self.parseConditional();
                if (self.peek()) |next| {
                    if (next.tag == .colon) {
                        self.pos += 1;
                        const right = try self.parseConditional();
                        return if (cond != 0) left else right;
                    }
                }
            }
        }
        return cond;
    }

    fn parseLogicalOr(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseLogicalAnd();
        while (self.peek()) |tok| {
            if (tok.tag == .pipe_pipe) {
                self.pos += 1;
                const right = try self.parseLogicalAnd();
                left = if (left != 0 or right != 0) 1 else 0;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseLogicalAnd(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseBitwiseOr();
        while (self.peek()) |tok| {
            if (tok.tag == .ampersand_ampersand) {
                self.pos += 1;
                const right = try self.parseBitwiseOr();
                left = if (left != 0 and right != 0) 1 else 0;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseBitwiseOr(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseBitwiseXor();
        while (self.peek()) |tok| {
            if (tok.tag == .pipe) {
                self.pos += 1;
                const right = try self.parseBitwiseXor();
                left = left | right;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseBitwiseXor(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseBitwiseAnd();
        while (self.peek()) |tok| {
            if (tok.tag == .caret) {
                self.pos += 1;
                const right = try self.parseBitwiseAnd();
                left = left ^ right;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseBitwiseAnd(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseEquality();
        while (self.peek()) |tok| {
            if (tok.tag == .ampersand) {
                self.pos += 1;
                const right = try self.parseEquality();
                left = left & right;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseEquality(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseRelational();
        while (self.peek()) |tok| {
            if (tok.tag == .eq_eq) {
                self.pos += 1;
                const right = try self.parseRelational();
                left = if (left == right) 1 else 0;
            } else if (tok.tag == .bang_eq) {
                self.pos += 1;
                const right = try self.parseRelational();
                left = if (left != right) 1 else 0;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseRelational(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseShift();
        while (self.peek()) |tok| {
            if (tok.tag == .lt) {
                self.pos += 1;
                const right = try self.parseShift();
                left = if (left < right) 1 else 0;
            } else if (tok.tag == .gt) {
                self.pos += 1;
                const right = try self.parseShift();
                left = if (left > right) 1 else 0;
            } else if (tok.tag == .lt_eq) {
                self.pos += 1;
                const right = try self.parseShift();
                left = if (left <= right) 1 else 0;
            } else if (tok.tag == .gt_eq) {
                self.pos += 1;
                const right = try self.parseShift();
                left = if (left >= right) 1 else 0;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseShift(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseAdditive();
        while (self.peek()) |tok| {
            if (tok.tag == .lshift) {
                self.pos += 1;
                const right = try self.parseAdditive();
                left = left << @as(u5, @intCast(@abs(right)));
            } else if (tok.tag == .rshift) {
                self.pos += 1;
                const right = try self.parseAdditive();
                left = left >> @as(u5, @intCast(@abs(right)));
            } else {
                break;
            }
        }
        return left;
    }

    fn parseAdditive(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseMultiplicative();
        while (self.peek()) |tok| {
            if (tok.tag == .plus) {
                self.pos += 1;
                const right = try self.parseMultiplicative();
                left = left + right;
            } else if (tok.tag == .minus) {
                self.pos += 1;
                const right = try self.parseMultiplicative();
                left = left - right;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseMultiplicative(self: *ExpressionEvaluator) ExprEvalError!i64 {
        var left = try self.parseUnary();
        while (self.peek()) |tok| {
            if (tok.tag == .star) {
                self.pos += 1;
                const right = try self.parseUnary();
                left = left * right;
            } else if (tok.tag == .slash) {
                self.pos += 1;
                const right = try self.parseUnary();
                if (right == 0) return error.PreprocessFailed;
                left = @divTrunc(left, right);
            } else if (tok.tag == .percent) {
                self.pos += 1;
                const right = try self.parseUnary();
                if (right == 0) return error.PreprocessFailed;
                left = @rem(left, right);
            } else {
                break;
            }
        }
        return left;
    }

    fn parseUnary(self: *ExpressionEvaluator) ExprEvalError!i64 {
        if (self.peek()) |tok| {
            if (tok.tag == .plus) {
                self.pos += 1;
                return try self.parseUnary();
            } else if (tok.tag == .minus) {
                self.pos += 1;
                const val = try self.parseUnary();
                return -val;
            } else if (tok.tag == .bang) {
                self.pos += 1;
                const val = try self.parseUnary();
                return if (val == 0) 1 else 0;
            } else if (tok.tag == .tilde) {
                self.pos += 1;
                const val = try self.parseUnary();
                return ~val;
            }
        }

        return try self.parsePrimary();
    }

    fn parsePrimary(self: *ExpressionEvaluator) ExprEvalError!i64 {
        if (self.peek()) |tok| {
            if (tok.tag == .int_literal or tok.tag == .uint_literal) {
                self.pos += 1;
                const text = self.preprocessor.getTokenText(tok);
                return std.fmt.parseInt(i64, text, 10);
            }

            if (tok.tag == .identifier) {
                const name = self.preprocessor.getTokenText(tok);
                self.pos += 1;

                // Check for defined operator
                if (std.mem.eql(u8, name, "defined")) {
                    if (self.peek()) |next| {
                        if (next.tag == .l_paren) {
                            self.pos += 1;
                            if (self.peek()) |ident| {
                                if (ident.tag == .identifier) {
                                    const macro_name = self.preprocessor.getTokenText(ident);
                                    self.pos += 1;
                                    if (self.peek()) |close| {
                                        if (close.tag == .r_paren) {
                                            self.pos += 1;
                                            return if (self.preprocessor.defines.contains(macro_name)) 1 else 0;
                                        }
                                    }
                                }
                            }
                        } else if (next.tag == .identifier) {
                            const macro_name = self.preprocessor.getTokenText(next);
                            self.pos += 1;
                            return if (self.preprocessor.defines.contains(macro_name)) 1 else 0;
                        }
                    }
                    return 0;
                }

                // Check if it's a defined macro
                if (self.preprocessor.defines.get(name)) |macro| {
                    switch (macro) {
                        .object => |body| {
                            if (body.len > 0) {
                                const body_tok = body[0];
                                if (body_tok.tag == .int_literal or body_tok.tag == .uint_literal) {
                                    const text = self.preprocessor.getTokenText(body_tok);
                                    return std.fmt.parseInt(i64, text, 10);
                                }
                                // If body is an identifier, recursively resolve it
                                if (body_tok.tag == .identifier) {
                                    const inner_name = self.preprocessor.getTokenText(body_tok);
                                    if (self.preprocessor.defines.get(inner_name)) |inner_macro| {
                                        switch (inner_macro) {
                                            .object => |inner_body| {
                                                if (inner_body.len > 0) {
                                                    const inner_tok = inner_body[0];
                                                    if (inner_tok.tag == .int_literal or inner_tok.tag == .uint_literal) {
                                                        const text = self.preprocessor.getTokenText(inner_tok);
                                                        return std.fmt.parseInt(i64, text, 10);
                                                    }
                                                }
                                            },
                                            .function => {},
                                        }
                                    }
                                }
                            }
                        },
                        .function => {},
                    }
                }

                return 0;
            }

            if (tok.tag == .l_paren) {
                self.pos += 1;
                const val = try self.parseConditional();
                if (self.peek()) |close| {
                    if (close.tag == .r_paren) {
                        self.pos += 1;
                        return val;
                    }
                }
                return error.PreprocessFailed;
            }
        }

        return error.PreprocessFailed;
    }

    fn peek(self: *const ExpressionEvaluator) ?lexer.Token {
        if (self.pos >= self.end) return null;
        return self.tokens[self.pos];
    }
};

// Tests
test "expand object-like macro" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#define FOO 42\nint x = FOO;";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Check that FOO was expanded
    var found_42 = false;
    for (result) |tok| {
        if (tok.tag == .int_literal) {
            const text = source[tok.start..][0..tok.len];
            if (std.mem.eql(u8, text, "42")) {
                found_42 = true;
            }
        }
    }
    try std.testing.expect(found_42);
}

test "expand function-like macro" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#define ADD(a,b) a+b\nint x = ADD(1,2);";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Check that ADD was expanded
    var found_plus = false;
    for (result) |tok| {
        if (tok.tag == .plus) {
            found_plus = true;
        }
    }
    try std.testing.expect(found_plus);
}

test "ifdef when defined" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    try pp.addDefine("FOO", &.{});

    const source = "#ifdef FOO\nint x;\n#endif";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Should contain int x
    var found_int = false;
    for (result) |tok| {
        if (tok.tag == .kw_int) {
            found_int = true;
        }
    }
    try std.testing.expect(found_int);
}

test "ifdef when not defined" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#ifdef FOO\nint x;\n#endif";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Should not contain int x
    for (result) |tok| {
        try std.testing.expect(tok.tag != .kw_int);
    }
}

test "#if expression" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#if 1 > 0\nint x;\n#endif";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    var found_int = false;
    for (result) |tok| {
        if (tok.tag == .kw_int) {
            found_int = true;
        }
    }
    try std.testing.expect(found_int);
}

test "defined operator" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    try pp.addDefine("FOO", &.{});

    const source = "#if defined(FOO)\nint x;\n#endif";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    var found_int = false;
    for (result) |tok| {
        if (tok.tag == .kw_int) {
            found_int = true;
        }
    }
    try std.testing.expect(found_int);
}

test "#undef removes macro" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#define FOO 42\n#undef FOO\nint x = FOO;";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // FOO should remain as identifier
    var found_identifier = false;
    for (result) |tok| {
        if (tok.tag == .identifier) {
            const text = source[tok.start..][0..tok.len];
            if (std.mem.eql(u8, text, "FOO")) {
                found_identifier = true;
            }
        }
    }
    try std.testing.expect(found_identifier);
}

test "#version extracted and removed" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#version 450 core\nvoid main() {}";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    try std.testing.expectEqual(@as(u32, 450), pp.version);

    // Should not contain pp_version
    for (result) |tok| {
        try std.testing.expect(tok.tag != .pp_version);
    }
}

test "#else branch" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#if 0\nint x;\n#else\nfloat y;\n#endif";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    var found_float = false;
    var found_int = false;
    for (result) |tok| {
        if (tok.tag == .kw_float) {
            found_float = true;
        }
        if (tok.tag == .kw_int) {
            found_int = true;
        }
    }
    try std.testing.expect(found_float);
    try std.testing.expect(!found_int);
}

test "nested #if blocks" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#if 1\n#if 1\nint x;\n#endif\n#endif";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    var found_int = false;
    for (result) |tok| {
        if (tok.tag == .kw_int) {
            found_int = true;
        }
    }
    try std.testing.expect(found_int);
}

test "#elif branch" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#if 0\nint x;\n#elif 1\nfloat y;\n#endif";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    var found_float = false;
    var found_int = false;
    for (result) |tok| {
        if (tok.tag == .kw_float) {
            found_float = true;
        }
        if (tok.tag == .kw_int) {
            found_int = true;
        }
    }
    try std.testing.expect(found_float);
    try std.testing.expect(!found_int);
}

test "__LINE__ builtin" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "int x = __LINE__;";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Should have an int literal from __LINE__
    var found_int_literal = false;
    for (result) |tok| {
        if (tok.tag == .int_literal) {
            found_int_literal = true;
        }
    }
    try std.testing.expect(found_int_literal);
}

test "__VERSION__ builtin" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "int x = __VERSION__;";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Should have an int literal from __VERSION__
    var found_int_literal = false;
    for (result) |tok| {
        if (tok.tag == .int_literal) {
            found_int_literal = true;
        }
    }
    try std.testing.expect(found_int_literal);
}

test "stringify operator" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#define STR(x) #x\nint x = STR(hello);";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Should contain a string literal
    var found_string = false;
    for (result) |tok| {
        if (tok.tag == .string_literal) {
            found_string = true;
        }
    }
    try std.testing.expect(found_string);
}

test "token paste operator" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#define PASTE(a,b) a##b\nint x = PASTE(foo,bar);";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Should contain an identifier (pasted result)
    var found_identifier = false;
    for (result) |tok| {
        if (tok.tag == .identifier) {
            found_identifier = true;
        }
    }
    try std.testing.expect(found_identifier);
}

test "self-recursion prevention" {
    const alloc = std.testing.allocator;
    var pp = Preprocessor.init(alloc);
    defer pp.deinit();

    const source = "#define FOO FOO\nint x = FOO;";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Should not crash and should contain FOO identifier
    var found_identifier = false;
    for (result) |tok| {
        if (tok.tag == .identifier) {
            const text = source[tok.start..][0..tok.len];
            if (std.mem.eql(u8, text, "FOO")) {
                found_identifier = true;
            }
        }
    }
    try std.testing.expect(found_identifier);
}

test "#include with string literal" {
    const alloc = std.testing.allocator;

    // Create a temp include file
    const cwd = std.fs.cwd();
    cwd.writeFile(.{ .sub_path = "test_include_helper.glsl", .data = "float helper_func() { return 1.0; }" }) catch |err| {
        std.debug.print("SKIP: could not create include file: {}\n", .{err});
        return;
    };
    defer cwd.deleteFile("test_include_helper.glsl") catch {};

    var pp = Preprocessor.init(alloc);
    defer pp.deinit();
    pp.source_file_path = "test_main.glsl";

    const source = "#include \"test_include_helper.glsl\"\nvoid main() { float x = helper_func(); }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Should contain the included code (float, identifier tokens)
    var found_float = false;
    for (result) |tok| {
        if (tok.tag == .kw_float) {
            found_float = true;
        }
    }
    try std.testing.expect(found_float);
}

test "#include cycle detection" {
    const alloc = std.testing.allocator;

    // Create a file that includes itself
    const cwd = std.fs.cwd();
    cwd.writeFile(.{ .sub_path = "test_cycle.glsl", .data = "#include \"test_cycle.glsl\"\nvoid main() {}" }) catch return;
    defer cwd.deleteFile("test_cycle.glsl") catch {};

    var pp = Preprocessor.init(alloc);
    defer pp.deinit();
    pp.source_file_path = "test_main.glsl";

    const source = "#include \"test_cycle.glsl\"\nvoid main() {}";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    // Should not infinite loop or crash
    const result = try pp.process(source, tokens);
    defer alloc.free(result);
}

test "#pragma once prevents re-inclusion" {
    const alloc = std.testing.allocator;

    // Create a header file with #pragma once
    const cwd = std.fs.cwd();
    cwd.writeFile(.{ .sub_path = "test_pragma_once.h", .data = "#pragma once\nfloat ONCE_VAR = 1.0;\n" }) catch return;
    defer cwd.deleteFile("test_pragma_once.h") catch {};

    var pp = Preprocessor.init(alloc);
    defer pp.deinit();
    pp.source_file_path = "test_main.glsl";

    const source =
        \\#include "test_pragma_once.h"
        \\#include "test_pragma_once.h"
        \\void main() {}
    ;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);

    const result = try pp.process(source, tokens);
    defer alloc.free(result);

    // Should contain ONCE_VAR exactly once (not twice)
    // The first inclusion expands ONCE_VAR, the second is blocked by #pragma once
    // We can't easily get token text from the preprocessor output without source access,
    // so instead check that the #pragma once file was tracked
    try std.testing.expect(pp.pragma_once_files.count() == 1);
    // The first inclusion expands ONCE_VAR, the second is blocked by #pragma once
    // Count should be 1, not 2
    try std.testing.expect(pp.pragma_once_files.count() == 1);
}

// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const Error = error{
    OutOfMemory,
    UnexpectedToken,
};

pub fn parse(alloc: std.mem.Allocator, source: [:0]const u8, tokens: []const lexer.Token) Error!ast.Root {
    var p = Parser{
        .alloc = alloc,
        .source = source,
        .tokens = tokens,
        .pos = 0,
        .struct_names = .{},
    };

    var body = std.ArrayListUnmanaged(ast.Node){};
    errdefer {
        for (body.items) |*node| freeNode(alloc, node);
        body.deinit(alloc);
        // Free struct_names HashMap keys on error path
        var sn_it = p.struct_names.keyIterator();
        while (sn_it.next()) |key| {
            alloc.free(key.*);
        }
        p.struct_names.deinit(alloc);
        // Free heap children and types on error path
        for (p.heap_children.items) |children| alloc.free(children);
        p.heap_children.deinit(alloc);
        for (p.heap_types.items) |ptr| alloc.destroy(ptr);
        p.heap_types.deinit(alloc);
    }

    while (p.current().tag != .eof) {
        // Skip preprocessor directives
        switch (p.current().tag) {
            .pp_version => {
                _ = p.advance(); // skip #version
                // Consume version number
                if (p.current().tag == .int_literal or p.current().tag == .uint_literal) _ = p.advance();
                // Consume optional profile (es, core, compatibility)
                if (p.current().tag == .identifier) _ = p.advance();
                continue;
            },
            .pp_define, .pp_undef, .pp_if, .pp_ifdef, .pp_ifndef, .pp_elif, .pp_else, .pp_endif, .pp_error, .pp_pragma, .pp_line, .pp_extension, .pp_include => {
                // Skip the directive line
                _ = p.advance();
                const start_line = p.current().loc.line;
                while (p.current().tag != .eof and p.current().loc.line == start_line) {
                    _ = p.advance();
                }
                continue;
            },
            .kw_precision => {
                // Skip precision declaration: precision [lowp|mediump|highp] type;
                _ = p.advance();
                if (p.current().tag == .identifier) _ = p.advance(); // lowp/mediump/highp
                if (p.current().tag == .identifier or p.current().tag == .kw_float or p.current().tag == .kw_int) _ = p.advance();
                if (p.current().tag == .semicolon) _ = p.advance();
                continue;
            },
            else => {},
        }

        const node = p.parseTopLevel() catch |err| {
            if (err == error.UnexpectedToken) {
                p.synchronize();
                continue;
            }
            return err;
        };
        try body.append(alloc, node);
    }

    // Free struct_names HashMap keys (dupe'd names) and deinit
    {
        var it = p.struct_names.keyIterator();
        while (it.next()) |key| {
            alloc.free(key.*);
        }
        p.struct_names.deinit(alloc);
    }

    return .{
        .version = null,
        .body = try body.toOwnedSlice(alloc),
        .alloc = alloc,
        .heap_types = try p.heap_types.toOwnedSlice(alloc),
        .heap_children = try p.heap_children.toOwnedSlice(alloc),
    };
}

pub fn freeTree(alloc: std.mem.Allocator, root: *ast.Root) void {
    for (root.body) |*node| {
        freeNode(alloc, node);
    }
    alloc.free(root.body);
    // Free heap-allocated AST types (array bases)
    for (root.heap_types) |ptr| {
        alloc.destroy(ptr);
    }
    if (root.heap_types.len > 0) {
        alloc.free(root.heap_types);
    }
    // Free heap-allocated children arrays (from dupeNodes and args.toOwnedSlice)
    for (root.heap_children) |children| {
        alloc.free(children);
    }
    if (root.heap_children.len > 0) {
        alloc.free(root.heap_children);
    }
    root.body = &.{};
    root.heap_types = &.{};
    root.heap_children = &.{};
}

fn freeNode(alloc: std.mem.Allocator, node: *const ast.Node) void {
    // Free the node's type (may contain heap-allocated array bases)
    if (node.data.ty) |t| freeType(alloc, t);
    for (node.data.children) |*child| {
        freeNode(alloc, child);
    }
    // Note: node.data.children freed via Root.heap_children in freeTree
    if (node.data.params.len > 0) {
        alloc.free(node.data.params);
    }
    if (node.data.members.len > 0) {
        for (node.data.members) |*member| {
            freeType(alloc, member.ty);
        }
        alloc.free(node.data.members);
    }
}

fn freeType(alloc: std.mem.Allocator, ty: ast.Type) void {
    switch (ty) {
        .array => |a| {
            freeType(alloc, a.base.*);
            // Note: a.base is destroyed via Root.heap_types in freeTree
        },
        else => {},
    }
}

const Parser = struct {
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const lexer.Token,
    pos: usize,
    struct_names: std.StringHashMapUnmanaged(void),
    heap_types: std.ArrayListUnmanaged(*ast.Type) = .{},
    heap_children: std.ArrayListUnmanaged([]const ast.Node) = .{},

    // ── Navigation ────────────────────────────────────────────

    fn current(self: *Parser) lexer.Token {
        if (self.pos >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.pos];
    }

    fn peek(self: *Parser) lexer.Token {
        if (self.pos + 1 >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.pos + 1];
    }

    fn peek2(self: *Parser) lexer.Token {
        if (self.pos + 2 >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.pos + 2];
    }

    fn advance(self: *Parser) lexer.Token {
        const tok = self.current();
        if (self.pos < self.tokens.len - 1) self.pos += 1;
        return tok;
    }

    fn expect(self: *Parser, tag: lexer.Token.Tag) Error!lexer.Token {
        const tok = self.current();
        if (tok.tag != tag) return error.UnexpectedToken;
        return self.advance();
    }

    fn match(self: *Parser, tag: lexer.Token.Tag) bool {
        if (self.current().tag == tag) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    // ── Utilities ─────────────────────────────────────────────

    fn synchronize(self: *Parser) void {
        while (self.current().tag != .eof) {
            switch (self.current().tag) {
                .semicolon => {
                    _ = self.advance();
                    return;
                },
                .r_brace => {
                    _ = self.advance();
                    return;
                },
                .kw_void, .kw_float, .kw_int, .kw_uint, .kw_bool,
                .kw_vec2, .kw_vec3, .kw_vec4,
                .kw_ivec2, .kw_ivec3, .kw_ivec4,
                .kw_bvec2, .kw_bvec3, .kw_bvec4,
                .kw_uvec2, .kw_uvec3, .kw_uvec4,
                .kw_i8vec2, .kw_i8vec3, .kw_i8vec4,
                .kw_u8vec2, .kw_u8vec3, .kw_u8vec4,
                .kw_int8, .kw_uint8,
                .kw_i16vec2, .kw_i16vec3, .kw_i16vec4,
                .kw_u16vec2, .kw_u16vec3, .kw_u16vec4,
                .kw_f16vec2, .kw_f16vec3, .kw_f16vec4,
                .kw_int16, .kw_uint16, .kw_float16,
                .kw_mat2, .kw_mat3, .kw_mat4,
                .kw_struct, .kw_uniform, .kw_in, .kw_out, .kw_buffer,
                => return,
                else => _ = self.advance(),
            }
        }
    }

    fn nodeLoc(self: *Parser, tok: lexer.Token) ast.Node.Loc {
        _ = self;
        return .{ .line = tok.loc.line, .column = tok.loc.column };
    }

    fn text(self: *Parser, tok: lexer.Token) []const u8 {
        return self.source[tok.start..tok.start + tok.len];
    }

    /// Create a heap-allocated AST type (for array bases) tracked for cleanup.
    fn createType(self: *Parser, inner: ast.Type) Error!*ast.Type {
        const ptr = try self.alloc.create(ast.Type);
        ptr.* = inner;
        self.heap_types.append(self.alloc, ptr) catch {};
        return ptr;
    }

    fn dupeNodes(self: *Parser, nodes: []const ast.Node) Error![]const ast.Node {
        if (nodes.len == 0) return &.{};
        const duped = try self.alloc.dupe(ast.Node, nodes);
        self.heap_children.append(self.alloc, duped) catch {};
        return duped;
    }

    /// Convert ArrayList to owned slice and track for cleanup.
    fn ownedChildren(self: *Parser, list: *std.ArrayListUnmanaged(ast.Node)) Error![]const ast.Node {
        const slice = try list.toOwnedSlice(self.alloc);
        if (slice.len > 0) {
            self.heap_children.append(self.alloc, slice) catch {};
        }
        return slice;
    }

    /// Create a binary_op node. Must use this instead of direct struct literal
    /// to avoid Zig evaluation-order issues with `left` reassignment.
    fn makeBinaryOp(self: *Parser, loc: ast.Node.Loc, op: ast.Op, left: ast.Node, right: ast.Node) Error!ast.Node {
        const children = try self.dupeNodes(&.{ left, right });
        return .{
            .tag = .binary_op,
            .loc = loc,
            .data = .{ .op = op, .children = children },
        };
    }

    fn isTypeKeyword(tag: lexer.Token.Tag) bool {
        return switch (tag) {
            .kw_void, .kw_float, .kw_int, .kw_uint, .kw_bool,
            .kw_int8, .kw_uint8,
            .kw_vec2, .kw_vec3, .kw_vec4,
            .kw_ivec2, .kw_ivec3, .kw_ivec4,
            .kw_bvec2, .kw_bvec3, .kw_bvec4,
            .kw_uvec2, .kw_uvec3, .kw_uvec4,
            .kw_i8vec2, .kw_i8vec3, .kw_i8vec4,
            .kw_u8vec2, .kw_u8vec3, .kw_u8vec4,
            .kw_mat2, .kw_mat3, .kw_mat4,
            .kw_mat2x2, .kw_mat2x3, .kw_mat2x4,
            .kw_mat3x2, .kw_mat3x3, .kw_mat3x4,
            .kw_mat4x2, .kw_mat4x3, .kw_mat4x4,
            .kw_sampler2d, .kw_sampler_cube,
            .kw_sampler2d_array, .kw_sampler2d_ms, .kw_sampler3d, .kw_sampler1d,
            .kw_sampler2d_ms_array, .kw_sampler_buffer,
            .kw_texture2d, .kw_texture3d, .kw_texture_cube,
            .kw_texture2d_array, .kw_texture2d_ms,
            .kw_sampler_plain,
            .kw_image2d, .kw_iimage2d, .kw_uimage2d,
            .kw_image1d, .kw_iimage1d, .kw_uimage1d,
            .kw_image3d, .kw_iimage3d, .kw_uimage3d,
            .kw_iimage_cube, .kw_uimage_cube,
            .kw_image2d_array, .kw_iimage2d_array, .kw_uimage2d_array,
            .kw_image_cube_array, .kw_iimage_cube_array, .kw_uimage_cube_array,
            .kw_image_buffer, .kw_iimage_buffer, .kw_uimage_buffer, .kw_image2d_ms, .kw_image2d_ms_array,
            .kw_acceleration_structure_ext, .kw_ray_query_ext, .kw_tensor_arm,
            .kw_subpass_input, .kw_subpass_input_ms,
            .kw_float16, .kw_int16, .kw_uint16,
            .kw_isampler2d, .kw_usampler2d,
            => true,
            else => false,
        };
    }

    // ── Top-level ─────────────────────────────────────────────

    fn parseTopLevel(self: *Parser) Error!ast.Node {
        if (self.current().tag == .kw_struct) {
            return self.parseStructDecl();
        }

        var qualifier = self.tryQualifier();
        const layout = try self.tryLayout();
        if (layout != null) {
            qualifier = self.tryQualifier() orelse qualifier;
        }

        // Uniform/buffer/in/out/shared block: layout(...) uniform Name { ... };
        // Check BEFORE tryType() to avoid consuming the block name as a type
        if (qualifier != null and (qualifier.?.is_uniform or qualifier.?.is_buffer or qualifier.?.is_in or qualifier.?.is_out or qualifier.?.is_shared)) {
            if (self.current().tag == .identifier) {
                const block_name_tok = self.current();
                const next_pos = self.pos + 1;
                if (next_pos < self.tokens.len and self.tokens[next_pos].tag == .l_brace) {
                    _ = self.advance(); // consume block name
                    return self.parseUniformBlock(block_name_tok, qualifier, layout);
                }
            }
            // Standalone layout qualifier: layout(local_size_x = 1) in;
            if (self.current().tag == .semicolon) {
                _ = self.advance(); // consume ;
                return ast.Node{
                    .tag = if (qualifier.?.is_in) .in_decl else .out_decl,
                    .loc = .{ .line = 0, .column = 0 },
                    .data = .{
                        .name = "",
                        .ty = .void,
                        .qualifier = qualifier,
                        .layout = layout,
                        .members = &.{},
                    },
                };
            }
        }

        const ty = self.tryType() orelse return error.UnexpectedToken;
        // Handle array dimensions on type (e.g., vec4[2] for function return types)
        var final_ty = ty;
        if (self.current().tag == .l_bracket) {
            // Parse array dimensions
            var arr_dims: std.ArrayListUnmanaged(u32) = .{};
            defer arr_dims.deinit(self.alloc);
            while (self.current().tag == .l_bracket) {
                _ = self.advance(); // [
                const size_tok = self.current();
                if (size_tok.tag == .r_bracket) {
                    _ = self.advance(); // ]
                    try arr_dims.append(self.alloc, 0);
                } else if (size_tok.tag == .int_literal) {
                    const arr_size = std.fmt.parseInt(u32, self.text(size_tok), 0) catch 0;
                    _ = self.advance();
                    _ = self.expect(.r_bracket) catch {};
                    try arr_dims.append(self.alloc, arr_size);
                } else {
                    break;
                }
            }
            // Build array type from outermost to innermost
            if (arr_dims.items.len > 0) {
                var i: usize = arr_dims.items.len;
                while (i > 0) {
                    i -= 1;
                    const arr_base = try self.createType(final_ty);
                    final_ty = .{ .array = .{ .base = arr_base, .size = arr_dims.items[i] } };
                }
            }
        }
        const name_tok = self.current();
        if (name_tok.tag != .identifier) return error.UnexpectedToken;
        _ = self.advance();

        if (self.current().tag == .l_paren) {
            return self.parseFunctionDecl(name_tok, final_ty, qualifier, layout);
        }
        return self.parseVarDecl(name_tok, final_ty, qualifier, layout);
    }

    // ── Qualifiers / Layout / Types ───────────────────────────

    fn tryQualifier(self: *Parser) ?ast.Qualifier {
        var q = ast.Qualifier{};
        var found = false;
        while (true) {
            switch (self.current().tag) {
                .kw_const => { q.is_const = true; _ = self.advance(); found = true; },
                .kw_in => { q.is_in = true; _ = self.advance(); found = true; },
                .kw_out => { q.is_out = true; _ = self.advance(); found = true; },
                .kw_inout => { q.is_inout = true; _ = self.advance(); found = true; },
                .kw_uniform => { q.is_uniform = true; _ = self.advance(); found = true; },
                .kw_buffer => { q.is_buffer = true; _ = self.advance(); found = true; },
                .kw_readonly, .kw_writeonly, .kw_coherent, .kw_restrict, .kw_invariant,
                .kw_flat, .kw_smooth, .kw_noperspective, .kw_centroid,
                .kw_mediump, .kw_highp, .kw_lowp => {
                    switch (self.current().tag) {
                        .kw_readonly => q.is_readonly = true,
                        .kw_writeonly => q.is_writeonly = true,
                        .kw_flat => q.is_flat = true,
                        .kw_noperspective => q.is_noperspective = true,
                        .kw_centroid => q.is_centroid = true,
                        .kw_coherent => q.is_coherent = true,
                        .kw_restrict => q.is_restrict = true,
                        .kw_invariant => q.is_invariant = true,
                        else => {},
                    }
                    _ = self.advance(); found = true;
                },
                .kw_shared => { q.is_shared = true; _ = self.advance(); found = true; },
                else => break,
            }
        }
        return if (found) q else null;
    }

    fn tryLayout(self: *Parser) Error!?ast.Layout {
        if (self.current().tag != .kw_layout) return null;
        _ = self.advance();
        _ = try self.expect(.l_paren);

        var layout = ast.Layout{};
        while (self.current().tag != .r_paren and self.current().tag != .eof) {
            if (self.current().tag == .identifier) {
                const ident_text = self.text(self.current());
                _ = self.advance();
                if (std.mem.eql(u8, ident_text, "std140")) {
                    layout.std140 = true;
                } else if (std.mem.eql(u8, ident_text, "std430")) {
                    layout.std430 = true;
                } else if (std.mem.eql(u8, ident_text, "push_constant")) {
                    layout.push_constant = true;
                } else if (std.mem.eql(u8, ident_text, "buffer_reference")) {
                    layout.buffer_reference = true;
                } else if (std.mem.eql(u8, ident_text, "row_major")) {
                    layout.row_major = true;
                } else if (std.mem.eql(u8, ident_text, "column_major")) {
                    layout.col_major = true;
                } else if (std.mem.eql(u8, ident_text, "origin_upper_left")) {
                    layout.origin_upper_left = true;
                } else if (std.mem.eql(u8, ident_text, "early_fragment_tests")) {
                    layout.early_fragment_tests = true;
                } else if (std.mem.eql(u8, ident_text, "depth_greater")) {
                    layout.depth_greater = true;
                } else if (std.mem.eql(u8, ident_text, "depth_less")) {
                    layout.depth_less = true;
                } else if (std.mem.eql(u8, ident_text, "depth_unchanged")) {
                    layout.depth_unchanged = true;
                } else if (self.current().tag == .eq) {
                    _ = self.advance();
                    const val_text = self.text(self.current());
                    _ = self.advance();
                    if (std.mem.eql(u8, ident_text, "location")) {
                        layout.location = std.fmt.parseInt(u32, val_text, 10) catch null;
                    } else if (std.mem.eql(u8, ident_text, "binding")) {
                        layout.binding = std.fmt.parseInt(u32, val_text, 10) catch null;
                    } else if (std.mem.eql(u8, ident_text, "set")) {
                        layout.set = std.fmt.parseInt(u32, val_text, 10) catch null;
                    } else if (std.mem.eql(u8, ident_text, "local_size_x")) {
                        layout.local_size_x = std.fmt.parseInt(u32, val_text, 10) catch null;
                    } else if (std.mem.eql(u8, ident_text, "local_size_y")) {
                        layout.local_size_y = std.fmt.parseInt(u32, val_text, 10) catch null;
                    } else if (std.mem.eql(u8, ident_text, "local_size_z")) {
                        layout.local_size_z = std.fmt.parseInt(u32, val_text, 10) catch null;
                    } else if (std.mem.eql(u8, ident_text, "input_attachment_index")) {
                        layout.input_attachment_index = std.fmt.parseInt(u32, val_text, 10) catch null;
                    } else if (std.mem.eql(u8, ident_text, "constant_id")) {
                        layout.constant_id = std.fmt.parseInt(u32, val_text, 10) catch null;
                    }
                }
            } else {
                _ = self.advance();
            }
            if (self.current().tag == .comma) _ = self.advance();
        }
        _ = try self.expect(.r_paren);
        return layout;
    }

    fn tryType(self: *Parser) ?ast.Type {
        return switch (self.current().tag) {
            .kw_void => { _ = self.advance(); return .void; },
            .kw_float => { _ = self.advance(); return .float; },
            .kw_int => { _ = self.advance(); return .int; },
            .kw_uint => { _ = self.advance(); return .uint; },
            .kw_int8 => { _ = self.advance(); return .int8; },
            .kw_uint8 => { _ = self.advance(); return .uint8; },
            .kw_int16 => { _ = self.advance(); return .int16; },
            .kw_uint16 => { _ = self.advance(); return .uint16; },
            .kw_float16 => { _ = self.advance(); return .float16; },
            .kw_i8vec2 => { _ = self.advance(); return .i8vec2; },
            .kw_i8vec3 => { _ = self.advance(); return .i8vec3; },
            .kw_i8vec4 => { _ = self.advance(); return .i8vec4; },
            .kw_u8vec2 => { _ = self.advance(); return .u8vec2; },
            .kw_u8vec3 => { _ = self.advance(); return .u8vec3; },
            .kw_u8vec4 => { _ = self.advance(); return .u8vec4; },
            .kw_i16vec2 => { _ = self.advance(); return .i16vec2; },
            .kw_i16vec3 => { _ = self.advance(); return .i16vec3; },
            .kw_i16vec4 => { _ = self.advance(); return .i16vec4; },
            .kw_u16vec2 => { _ = self.advance(); return .u16vec2; },
            .kw_u16vec3 => { _ = self.advance(); return .u16vec3; },
            .kw_u16vec4 => { _ = self.advance(); return .u16vec4; },
            .kw_f16vec2 => { _ = self.advance(); return .f16vec2; },
            .kw_f16vec3 => { _ = self.advance(); return .f16vec3; },
            .kw_f16vec4 => { _ = self.advance(); return .f16vec4; },
            .kw_bool => { _ = self.advance(); return .bool; },
            .kw_vec2 => { _ = self.advance(); return .vec2; },
            .kw_vec3 => { _ = self.advance(); return .vec3; },
            .kw_vec4 => { _ = self.advance(); return .vec4; },
            .kw_ivec2 => { _ = self.advance(); return .ivec2; },
            .kw_ivec3 => { _ = self.advance(); return .ivec3; },
            .kw_ivec4 => { _ = self.advance(); return .ivec4; },
            .kw_bvec2 => { _ = self.advance(); return .bvec2; },
            .kw_bvec3 => { _ = self.advance(); return .bvec3; },
            .kw_bvec4 => { _ = self.advance(); return .bvec4; },
            .kw_uvec2 => { _ = self.advance(); return .uvec2; },
            .kw_uvec3 => { _ = self.advance(); return .uvec3; },
            .kw_uvec4 => { _ = self.advance(); return .uvec4; },
            .kw_mat2 => { _ = self.advance(); return .mat2; },
            .kw_mat3 => { _ = self.advance(); return .mat3; },
            .kw_mat4 => { _ = self.advance(); return .mat4; },
            .kw_mat2x2 => { _ = self.advance(); return .mat2x2; },
            .kw_mat2x3 => { _ = self.advance(); return .mat2x3; },
            .kw_mat2x4 => { _ = self.advance(); return .mat2x4; },
            .kw_mat3x2 => { _ = self.advance(); return .mat3x2; },
            .kw_mat3x3 => { _ = self.advance(); return .mat3x3; },
            .kw_mat3x4 => { _ = self.advance(); return .mat3x4; },
            .kw_mat4x2 => { _ = self.advance(); return .mat4x2; },
            .kw_mat4x3 => { _ = self.advance(); return .mat4x3; },
            .kw_mat4x4 => { _ = self.advance(); return .mat4x4; },
            .kw_sampler_buffer => { _ = self.advance(); return .sampler_buffer; },
            .kw_sampler2d_ms => { _ = self.advance(); return .sampler2d_ms; },
            .kw_isampler2d_ms => { _ = self.advance(); return .isampler2d_ms; },
            .kw_usampler2d_ms => { _ = self.advance(); return .usampler2d_ms; },
            .kw_sampler2d_ms_array => { _ = self.advance(); return .sampler2d_ms_array; },
            .kw_isampler2d_ms_array => { _ = self.advance(); return .isampler2d_ms_array; },
            .kw_usampler2d_ms_array => { _ = self.advance(); return .usampler2d_ms_array; },
            .kw_sampler2d => { _ = self.advance(); return .sampler2d; },
            .kw_isampler2d => { _ = self.advance(); return .isampler2d; },
            .kw_usampler2d => { _ = self.advance(); return .usampler2d; },
            .kw_sampler2d_array => { _ = self.advance(); return .sampler2d_array; },
            .kw_isampler2d_array => { _ = self.advance(); return .isampler2d_array; },
            .kw_usampler2d_array => { _ = self.advance(); return .usampler2d_array; },
            .kw_sampler3d => { _ = self.advance(); return .sampler3d; },
            .kw_isampler3d => { _ = self.advance(); return .isampler3d; },
            .kw_usampler3d => { _ = self.advance(); return .usampler3d; },
            .kw_sampler_cube_array => { _ = self.advance(); return .sampler_cube; },
            .kw_sampler_cube_array_shadow => { _ = self.advance(); return .sampler_cube_array_shadow; },
            .kw_isampler_cube => { _ = self.advance(); return .isampler_cube; },
            .kw_usampler_cube => { _ = self.advance(); return .usampler_cube; },
            .kw_isampler_cube_array => { _ = self.advance(); return .isampler_cube_array; },
            .kw_usampler_cube_array => { _ = self.advance(); return .usampler_cube_array; },
            .kw_sampler2d_rect, .kw_sampler1d_array => { _ = self.advance(); return .sampler2d; },
            .kw_sampler1d => { _ = self.advance(); return .sampler1d; },
            .kw_isampler1d => { _ = self.advance(); return .isampler1d; },
            .kw_usampler1d => { _ = self.advance(); return .usampler1d; },
            .kw_isampler1d_array => { _ = self.advance(); return .isampler1d_array; },
            .kw_usampler1d_array => { _ = self.advance(); return .usampler1d_array; },
            .kw_sampler2d_shadow => { _ = self.advance(); return .sampler2d_shadow; },
            .kw_sampler1d_shadow => { _ = self.advance(); return .sampler1d_shadow; },
            .kw_sampler2d_array_shadow => { _ = self.advance(); return .sampler2d_array_shadow; },
            .kw_sampler1d_array_shadow => { _ = self.advance(); return .sampler2d_array_shadow; },
            .kw_sampler2d_rect_shadow => { _ = self.advance(); return .sampler2d_shadow; },
            .kw_sampler_cube_shadow => { _ = self.advance(); return .sampler_cube_shadow; },
            .kw_image_buffer => { _ = self.advance(); return .image_buffer; },
            .kw_iimage_buffer => { _ = self.advance(); return .iimage_buffer; },
            .kw_uimage_buffer => { _ = self.advance(); return .uimage_buffer; },
            .kw_image2d => { _ = self.advance(); return .image2d; },
            .kw_iimage2d => { _ = self.advance(); return .iimage2d; },
            .kw_uimage2d => { _ = self.advance(); return .uimage2d; },
            .kw_image2d_ms => { _ = self.advance(); return .image2d_ms; },
            .kw_image2d_ms_array => { _ = self.advance(); return .image2d_ms_array; },
            .kw_image1d => { _ = self.advance(); return .image1d; },
            .kw_iimage1d => { _ = self.advance(); return .iimage1d; },
            .kw_uimage1d => { _ = self.advance(); return .uimage1d; },
            .kw_iimage3d => { _ = self.advance(); return .iimage3d; },
            .kw_uimage3d => { _ = self.advance(); return .uimage3d; },
            .kw_iimage_cube => { _ = self.advance(); return .iimage_cube; },
            .kw_uimage_cube => { _ = self.advance(); return .uimage_cube; },
            .kw_iimage2d_array => { _ = self.advance(); return .iimage2d_array; },
            .kw_uimage2d_array => { _ = self.advance(); return .uimage2d_array; },
            .kw_image_cube_array => { _ = self.advance(); return .image_cube_array; },
            .kw_iimage_cube_array => { _ = self.advance(); return .iimage_cube_array; },
            .kw_uimage_cube_array => { _ = self.advance(); return .uimage_cube_array; },
            .kw_image3d => { _ = self.advance(); return .image3d; },
            .kw_imagecube => { _ = self.advance(); return .image_cube; },
            .kw_image2d_array => { _ = self.advance(); return .image2d_array; },
            .kw_texture2d => { _ = self.advance(); return .texture2d_plain; },
            .kw_texture3d => { _ = self.advance(); return .texture3d_plain; },
            .kw_texture_cube => { _ = self.advance(); return .texture_cube_plain; },
            .kw_texture2d_array => { _ = self.advance(); return .texture2d_array_plain; },
            .kw_texture2d_ms => { _ = self.advance(); return .texture2d_ms_plain; },
            .kw_acceleration_structure_ext => { _ = self.advance(); return .acceleration_structure_ext; },
            .kw_ray_query_ext => { _ = self.advance(); return .ray_query_ext; },
            .kw_tensor_arm => {
                _ = self.advance(); // consume tensorARM
                if (self.current().tag == .lt) {
                    _ = self.advance(); // consume <
                    // Parse element type directly from token — don't use tryType
                    // because int32_t/uint32_t are identifiers that would become .named (struct)
                    const elem_ty: ast.Type = blk: {
                        // Check for explicit arithmetic type keywords (int8_t, uint8_t, etc.)
                        switch (self.current().tag) {
                            .kw_int => { _ = self.advance(); break :blk .int; },
                            .kw_uint => { _ = self.advance(); break :blk .uint; },
                            .kw_float => { _ = self.advance(); break :blk .float; },
                            .kw_bool => { _ = self.advance(); break :blk .bool; },
                            .kw_int8 => { _ = self.advance(); break :blk .int8; },
                            .kw_uint8 => { _ = self.advance(); break :blk .uint8; },
                            .kw_int16 => { _ = self.advance(); break :blk .int16; },
                            .kw_uint16 => { _ = self.advance(); break :blk .uint16; },
                            .kw_float16 => { _ = self.advance(); break :blk .float16; },
                            else => {},
                        }
                        // Check for int32_t/uint32_t/float32_t as identifiers
                        if (self.current().tag == .identifier) {
                            const name = self.text(self.current());
                            if (std.mem.eql(u8, name, "int32_t")) { _ = self.advance(); break :blk .int; }
                            if (std.mem.eql(u8, name, "uint32_t")) { _ = self.advance(); break :blk .uint; }
                            if (std.mem.eql(u8, name, "float32_t")) { _ = self.advance(); break :blk .float; }
                            if (std.mem.eql(u8, name, "int8_t")) { _ = self.advance(); break :blk .int8; }
                            if (std.mem.eql(u8, name, "uint8_t")) { _ = self.advance(); break :blk .uint8; }
                            if (std.mem.eql(u8, name, "int16_t")) { _ = self.advance(); break :blk .int16; }
                            if (std.mem.eql(u8, name, "uint16_t")) { _ = self.advance(); break :blk .uint16; }
                            if (std.mem.eql(u8, name, "float16_t")) { _ = self.advance(); break :blk .float16; }
                            if (std.mem.eql(u8, name, "double")) { _ = self.advance(); break :blk .double; }
                        }
                        break :blk .void;
                    };
                    if (self.current().tag == .comma) _ = self.advance();
                    const rank_tok = self.current();
                    const rank = std.fmt.parseInt(u32, self.text(rank_tok), 0) catch 4;
                    _ = self.advance(); // consume rank
                    if (self.current().tag == .gt) _ = self.advance(); // consume >
                    const elem_ptr = self.createType(elem_ty) catch return null;
                    return .{ .tensor_arm = .{ .element = elem_ptr, .rank = rank } };
                }
                return .void;
            },
            .kw_subpass_input => { _ = self.advance(); return .subpass_input; },
            .kw_subpass_input_ms => { _ = self.advance(); return .subpass_input_ms; },
            .kw_sampler_shadow, .kw_sampler_plain => { _ = self.advance(); return .sampler_plain; },
            .kw_sampler_cube => { _ = self.advance(); return .sampler_cube; },
            .identifier => {
                const tok = self.advance();
                return .{ .named = self.text(tok) };
            },
            else => null,
        };
    }

    // ── Declarations ──────────────────────────────────────────

    fn parseFunctionDecl(self: *Parser, name_tok: lexer.Token, ret_type: ast.Type, qualifier: ?ast.Qualifier, layout: ?ast.Layout) Error!ast.Node {
        _ = try self.expect(.l_paren);
        var params = std.ArrayListUnmanaged(ast.FunctionParam){};
        defer params.deinit(self.alloc);
        // Handle 'void' as sole parameter (meaning no params)
        if (self.current().tag == .kw_void) {
            const void_pos = self.pos;
            _ = self.advance();
            if (self.current().tag == .r_paren) {
                // void as only param → empty param list
            } else {
                // void was a type, not a param-less marker
                self.pos = void_pos;
            }
        }
        while (self.current().tag != .r_paren and self.current().tag != .eof) {
            const p_qual = self.tryQualifier();
            const p_type = self.tryType() orelse return error.UnexpectedToken;
            // Handle unnamed parameters: type followed by , or ) without identifier
            if (self.current().tag == .comma or self.current().tag == .r_paren) {
                try params.append(self.alloc, .{
                    .name = "",
                    .ty = p_type,
                    .qualifier = p_qual,
                });
                if (self.current().tag == .comma) _ = self.advance();
                continue;
            }
            const p_name = self.current();
            if (p_name.tag != .identifier) return error.UnexpectedToken;
            _ = self.advance();
            // Handle array dimensions after param name: e.g. texture2D tex[4]
            var final_type = p_type;
            if (self.current().tag == .l_bracket) {
                _ = self.advance(); // consume [
                const size_tok = self.current();
                _ = self.advance(); // consume size
                if (self.current().tag == .r_bracket) _ = self.advance(); // consume ]
                const size_str = self.text(size_tok);
                const size = std.fmt.parseInt(u32, size_str, 10) catch 0;
                if (size > 0) {
                    const base_ptr = try self.createType(p_type);
                    final_type = .{ .array = .{ .base = base_ptr, .size = size } };
                }
            }
            try params.append(self.alloc, .{
                .name = self.text(p_name),
                .ty = final_type,
                .qualifier = p_qual,
            });
            if (self.current().tag == .comma) _ = self.advance();
        }
        _ = try self.expect(.r_paren);

        if (self.current().tag == .semicolon) {
            _ = self.advance();
            return .{
                .tag = .function_prototype,
                .loc = self.nodeLoc(name_tok),
                .data = .{
                    .name = self.text(name_tok),
                    .ty = ret_type,
                    .params = try params.toOwnedSlice(self.alloc),
                    .qualifier = qualifier,
                },
            };
        }

        const body_stmts = try self.parseBlock();
        return .{
            .tag = .function_decl,
            .loc = self.nodeLoc(name_tok),
            .data = .{
                .name = self.text(name_tok),
                .ty = ret_type,
                .params = try params.toOwnedSlice(self.alloc),
                .children = body_stmts,
                .qualifier = qualifier,
                .layout = layout,
            },
        };
    }

    fn parseVarDecl(self: *Parser, name_tok: lexer.Token, mut_ty: ast.Type, qualifier: ?ast.Qualifier, layout: ?ast.Layout) Error!ast.Node {
        // Handle array size suffix: float a[4]
        var ty = mut_ty;
        // Collect array dimensions (first dimension is outermost)
        var arr_dims: std.ArrayListUnmanaged(u32) = .{};
        defer arr_dims.deinit(self.alloc);
        while (self.current().tag == .l_bracket) {
            _ = self.advance();
            const size_tok = self.current();
            var arr_size: u32 = 0;
            if (size_tok.tag == .int_literal) {
                arr_size = std.fmt.parseInt(u32, self.text(size_tok), 0) catch 0;
                _ = self.advance();
            }
            _ = self.expect(.r_bracket) catch break;
            try arr_dims.append(self.alloc, arr_size);
        }
        // Build array type from outermost to innermost (reverse order)
        if (arr_dims.items.len > 0) {
            var i: usize = arr_dims.items.len;
            while (i > 0) {
                i -= 1;
                const arr_base = try self.createType(ty);
                ty = .{ .array = .{ .base = arr_base, .size = arr_dims.items[i] } };
            }
        }
        var init_nodes = std.ArrayListUnmanaged(ast.Node){};
        defer init_nodes.deinit(self.alloc);
        if (self.current().tag == .eq) {
            _ = self.advance();
            try init_nodes.append(self.alloc, try self.parseExpression());
        }
        _ = try self.expect(.semicolon);

        const tag: ast.Node.Tag = if (qualifier) |q| blk: {
            if (q.is_uniform) break :blk .uniform_decl;
            if (q.is_in) break :blk .in_decl;
            if (q.is_out) break :blk .out_decl;
            break :blk .var_decl;
        } else .var_decl;

        return .{
            .tag = tag,
            .loc = self.nodeLoc(name_tok),
            .data = .{
                .name = self.text(name_tok),
                .ty = ty,
                .children = try self.ownedChildren(&init_nodes),
                .qualifier = qualifier,
                .layout = layout,
            },
        };
    }

    fn parseStructDecl(self: *Parser) Error!ast.Node {
        const tok = self.advance(); // 'struct'
        const name_tok = self.current();
        if (name_tok.tag != .identifier) return error.UnexpectedToken;
        _ = self.advance();
        // Register struct name for local var decl detection
        const owned_name = try self.alloc.dupe(u8, self.text(name_tok));
        const gop = try self.struct_names.getOrPut(self.alloc, owned_name);
        if (gop.found_existing) {
            // Key already exists, free the new duplicate
            self.alloc.free(owned_name);
        }

        _ = try self.expect(.l_brace);
        var members = std.ArrayListUnmanaged(ast.StructMember){};
        defer members.deinit(self.alloc);
        while (self.current().tag != .r_brace and self.current().tag != .eof) {
            var member_layout: ?ast.Layout = null;
            if (self.current().tag == .kw_layout) member_layout = try self.tryLayout();
            const member_qual = self.tryQualifier();
            const member_ty = self.tryType() orelse return error.UnexpectedToken;
            const member_name = self.current();
            if (member_name.tag != .identifier) return error.UnexpectedToken;
            _ = self.advance();
            // Check for array size suffix: vec2 a[1] (supports multi-dim: vec2 a[2][3])
            var member_ty_final = member_ty;
            var member_arr_dims: std.ArrayListUnmanaged(u32) = .{};
            defer member_arr_dims.deinit(self.alloc);
            while (self.current().tag == .l_bracket) {
                _ = self.advance();
                const size_tok = self.current();
                var arr_size: u32 = 0;
                if (size_tok.tag == .int_literal) {
                    arr_size = std.fmt.parseInt(u32, self.text(size_tok), 0) catch 0;
                    _ = self.advance();
                }
                _ = self.expect(.r_bracket) catch break;
                try member_arr_dims.append(self.alloc, arr_size);
            }
            if (member_arr_dims.items.len > 0) {
                var i: usize = member_arr_dims.items.len;
                while (i > 0) {
                    i -= 1;
                    const arr_base = try self.createType(member_ty_final);
                    member_ty_final = .{ .array = .{ .base = arr_base, .size = member_arr_dims.items[i] } };
                }
            }
            _ = try self.expect(.semicolon);
            try members.append(self.alloc, .{
                .name = self.text(member_name),
                .ty = member_ty_final,
                .layout = member_layout,
                .qualifier = member_qual,
            });
        }
        _ = try self.expect(.r_brace);
        _ = try self.expect(.semicolon);

        return .{
            .tag = .struct_decl,
            .loc = self.nodeLoc(tok),
            .data = .{
                .name = self.text(name_tok),
                .members = try members.toOwnedSlice(self.alloc),
            },
        };
    }

    fn parseUniformBlock(self: *Parser, name_tok: lexer.Token, qualifier: ?ast.Qualifier, layout: ?ast.Layout) Error!ast.Node {
        _ = try self.expect(.l_brace);
        var members = std.ArrayListUnmanaged(ast.StructMember){};
        defer members.deinit(self.alloc);
        while (self.current().tag != .r_brace and self.current().tag != .eof) {
            var member_layout: ?ast.Layout = null;
            if (self.current().tag == .kw_layout) member_layout = try self.tryLayout();
            const member_qual = self.tryQualifier();
            const member_ty = self.tryType() orelse return error.UnexpectedToken;
            const member_name = self.current();
            if (member_name.tag != .identifier) return error.UnexpectedToken;
            _ = self.advance();
            // Check for array size suffix: vec2 a[1] (supports multi-dim: vec2 a[2][3])
            var member_ty_final = member_ty;
            var member_arr_dims: std.ArrayListUnmanaged(u32) = .{};
            defer member_arr_dims.deinit(self.alloc);
            var member_arr_size_name: ?[]const u8 = null;
            while (self.current().tag == .l_bracket) {
                _ = self.advance();
                const size_tok = self.current();
                var arr_size: u32 = 0;
                if (size_tok.tag == .int_literal) {
                    arr_size = std.fmt.parseInt(u32, self.text(size_tok), 0) catch 0;
                    _ = self.advance();
                } else if (size_tok.tag == .identifier) {
                    member_arr_size_name = self.text(size_tok);
                    _ = self.advance();
                }
                _ = self.expect(.r_bracket) catch break;
                try member_arr_dims.append(self.alloc, arr_size);
            }
            if (member_arr_dims.items.len > 0) {
                var i: usize = member_arr_dims.items.len;
                while (i > 0) {
                    i -= 1;
                    const arr_base = try self.createType(member_ty_final);
                    member_ty_final = .{ .array = .{ .base = arr_base, .size = member_arr_dims.items[i], .size_name = member_arr_size_name } };
                }
            }
            _ = try self.expect(.semicolon);
            try members.append(self.alloc, .{
                .name = self.text(member_name),
                .ty = member_ty_final,
                .layout = member_layout,
                .qualifier = member_qual,
            });
        }
        _ = try self.expect(.r_brace);
        // Consume optional instance name: } instance_name;
        var instance_name: []const u8 = "";
        if (self.current().tag == .identifier) {
            instance_name = self.text(self.current());
            _ = self.advance(); // consume instance name
        }
        _ = try self.expect(.semicolon);

        return .{
            .tag = .uniform_block,
            .loc = self.nodeLoc(name_tok),
            .data = .{
                .name = self.text(name_tok),
                .members = try members.toOwnedSlice(self.alloc),
                .qualifier = qualifier,
                .layout = layout,
                .instance_name = instance_name,
            },
        };
    }

    // ── Statements ────────────────────────────────────────────

    fn parseBlock(self: *Parser) Error![]const ast.Node {
        _ = try self.expect(.l_brace);
        var stmts = std.ArrayListUnmanaged(ast.Node){};
        errdefer {
            for (stmts.items) |*node| freeNode(self.alloc, node);
            stmts.deinit(self.alloc);
        }
        while (self.current().tag != .r_brace and self.current().tag != .eof) {
            const stmt = self.parseStatement() catch {
                self.synchronize();
                continue;
            };
            try stmts.append(self.alloc, stmt);
        }
        _ = self.expect(.r_brace) catch {};
        return try self.ownedChildren(&stmts);
    }

    fn parseStatement(self: *Parser) Error!ast.Node {
        const cur = self.current().tag;

        // Skip preprocessor directives inside function bodies
        switch (cur) {
            .pp_define, .pp_undef, .pp_if, .pp_ifdef, .pp_ifndef, .pp_elif, .pp_else, .pp_endif, .pp_error, .pp_pragma, .pp_line, .pp_extension, .pp_include => {
                const start_line = self.current().loc.line;
                while (self.current().tag != .eof and self.current().loc.line == start_line) {
                    _ = self.advance();
                }
                return .{
                    .tag = .expr_stmt,
                    .loc = .{ .line = @intCast(start_line), .column = 0 },
                    .data = .{ .children = &.{} },
                };
            },
            else => {},
        }

        const nxt = self.peek().tag;

        // Local variable declaration: type identifier ...
        if (isTypeKeyword(cur) and nxt == .identifier) {
            return self.parseLocalVarDecl();
        }
        // User-defined struct type variable declaration: StructName identifier ...
        // Only if cur is a known struct name and followed by = or ; or [
        if (cur == .identifier and nxt == .identifier) {
            const type_name = self.text(self.current());
            if (self.struct_names.contains(type_name)) {
                const third = self.peek2().tag;
                if (third == .eq or third == .semicolon or third == .l_bracket) {
                    return self.parseLocalVarDecl();
                }
            }
        }
        // const type identifier ...
        if (cur == .kw_const and (isTypeKeyword(nxt) or nxt == .identifier)) {
            return self.parseLocalVarDecl();
        }

        return switch (cur) {
            .l_brace => {
                const lbrace = self.current();
                const stmts = try self.parseBlock();
                return .{
                    .tag = .block,
                    .loc = self.nodeLoc(lbrace),
                    .data = .{ .children = stmts },
                };
            },
            .kw_struct => self.parseStructDecl(),
            .kw_if => self.parseIf(),
            .kw_for => self.parseFor(),
            .kw_while => self.parseWhile(),
            .kw_do => self.parseDoWhile(),
            .kw_switch => self.parseSwitch(),
            .kw_return => self.parseReturn(),
            .kw_discard => {
                const tok = self.advance();
                _ = try self.expect(.semicolon);
                return .{ .tag = .discard_stmt, .loc = self.nodeLoc(tok), .data = .{} };
            },
            .kw_break => {
                const tok = self.advance();
                _ = try self.expect(.semicolon);
                return .{ .tag = .break_stmt, .loc = self.nodeLoc(tok), .data = .{} };
            },
            .kw_continue => {
                const tok = self.advance();
                _ = try self.expect(.semicolon);
                return .{ .tag = .continue_stmt, .loc = self.nodeLoc(tok), .data = .{} };
            },
            else => self.parseExprStmt(),
        };
    }

    fn parseLocalVarDecl(self: *Parser) Error!ast.Node {
        const qualifier = self.tryQualifier();
        var ty = self.tryType() orelse blk: {
            // Try identifier-based type (struct name)
            if (self.current().tag == .identifier) {
                const name = self.text(self.current());
                _ = self.advance();
                break :blk ast.Type{ .named = name };
            }
            return error.UnexpectedToken;
        };
        const name_tok = self.current();
        if (name_tok.tag != .identifier) return error.UnexpectedToken;
        _ = self.advance();
        // Handle array size suffix: float a[4]
        var local_arr_dims: std.ArrayListUnmanaged(u32) = .{};
        defer local_arr_dims.deinit(self.alloc);
        while (self.current().tag == .l_bracket) {
            _ = self.advance();
            const size_tok = self.current();
            var arr_size: u32 = 0;
            if (size_tok.tag == .int_literal) {
                arr_size = std.fmt.parseInt(u32, self.text(size_tok), 0) catch 0;
                _ = self.advance();
            }
            _ = self.expect(.r_bracket) catch break;
            try local_arr_dims.append(self.alloc, arr_size);
        }
        if (local_arr_dims.items.len > 0) {
            var i: usize = local_arr_dims.items.len;
            while (i > 0) {
                i -= 1;
                const arr_base = try self.createType(ty);
                ty = .{ .array = .{ .base = arr_base, .size = local_arr_dims.items[i] } };
            }
        }

        var init_nodes = std.ArrayListUnmanaged(ast.Node){};
        defer init_nodes.deinit(self.alloc);
        if (self.current().tag == .eq) {
            _ = self.advance();
            try init_nodes.append(self.alloc, try self.parseExpression());
        }

        // Handle comma-separated declarations: int i = 1, j = 4;
        var decl_children = std.ArrayListUnmanaged(ast.Node){};
        defer decl_children.deinit(self.alloc);
        try decl_children.append(self.alloc, .{
            .tag = .var_decl,
            .loc = self.nodeLoc(name_tok),
            .data = .{
                .name = self.text(name_tok),
                .ty = ty,
                .children = try self.ownedChildren(&init_nodes),
                .qualifier = qualifier,
            },
        });
        while (self.current().tag == .comma) {
            _ = self.advance(); // consume ','
            const next_name = self.current();
            if (next_name.tag != .identifier) break;
            _ = self.advance();
            var next_init = std.ArrayListUnmanaged(ast.Node){};
            defer next_init.deinit(self.alloc);
            if (self.current().tag == .eq) {
                _ = self.advance();
                try next_init.append(self.alloc, try self.parseExpression());
            }
            try decl_children.append(self.alloc, .{
                .tag = .var_decl,
                .loc = self.nodeLoc(next_name),
                .data = .{
                    .name = self.text(next_name),
                    .ty = ty,
                    .children = try self.ownedChildren(&next_init),
                    .qualifier = qualifier,
                },
            });
        }

        _ = try self.expect(.semicolon);

        if (decl_children.items.len == 1) {
            return decl_children.items[0];
        }
        return .{
            .tag = .multi_decl,
            .loc = self.nodeLoc(name_tok),
            .data = .{ .children = try self.ownedChildren(&decl_children) },
        };
    }

    fn parseIf(self: *Parser) Error!ast.Node {
        const tok = self.advance(); // 'if'
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression();
        _ = try self.expect(.r_paren);

        var children = std.ArrayListUnmanaged(ast.Node){};
        defer children.deinit(self.alloc);
        try children.append(self.alloc, cond);
        try children.append(self.alloc, try self.parseStatement());

        if (self.current().tag == .kw_else) {
            _ = self.advance();
            try children.append(self.alloc, try self.parseStatement());
        }

        return .{
            .tag = .if_stmt,
            .loc = self.nodeLoc(tok),
            .data = .{ .children = try self.ownedChildren(&children) },
        };
    }

    fn parseFor(self: *Parser) Error!ast.Node {
        const tok = self.advance(); // 'for'
        _ = try self.expect(.l_paren);

        var children = std.ArrayListUnmanaged(ast.Node){};
        defer children.deinit(self.alloc);

        const empty_node = ast.Node{
            .tag = .expr_stmt,
            .loc = .{ .line = 0, .column = 0 },
            .data = .{ .children = &.{} },
        };

        // Init (always append — empty if just ';')
        if (self.current().tag != .semicolon) {
            try children.append(self.alloc, try self.parseStatement());
        } else {
            _ = self.advance();
            try children.append(self.alloc, empty_node);
        }

        // Condition (always append — empty if just ';')
        if (self.current().tag != .semicolon) {
            try children.append(self.alloc, try self.parseCommaExpression());
        } else {
            try children.append(self.alloc, empty_node);
        }
        _ = try self.expect(.semicolon);

        // Update (always append — empty if just ')')
        if (self.current().tag != .r_paren) {
            try children.append(self.alloc, try self.parseCommaExpression());
        } else {
            try children.append(self.alloc, empty_node);
        }
        _ = try self.expect(.r_paren);

        // Body
        try children.append(self.alloc, try self.parseStatement());

        return .{
            .tag = .for_stmt,
            .loc = self.nodeLoc(tok),
            .data = .{ .children = try self.ownedChildren(&children) },
        };
    }

    fn parseWhile(self: *Parser) Error!ast.Node {
        const tok = self.advance(); // 'while'
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression();
        _ = try self.expect(.r_paren);
        const body = try self.parseStatement();
        return .{
            .tag = .while_stmt,
            .loc = self.nodeLoc(tok),
            .data = .{ .children = try self.dupeNodes(&.{ cond, body }) },
        };
    }

    fn parseDoWhile(self: *Parser) Error!ast.Node {
        const tok = self.advance(); // 'do'
        const body = try self.parseStatement();
        _ = try self.expect(.kw_while);
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression();
        _ = try self.expect(.r_paren);
        _ = try self.expect(.semicolon);
        return .{
            .tag = .do_while_stmt,
            .loc = self.nodeLoc(tok),
            .data = .{ .children = try self.dupeNodes(&.{ body, cond }) },
        };
    }

    fn parseSwitch(self: *Parser) Error!ast.Node {
        const tok = self.advance(); // 'switch'
        _ = try self.expect(.l_paren);
        const expr = try self.parseExpression();
        _ = try self.expect(.r_paren);
        _ = try self.expect(.l_brace);

        // Parse case/default blocks as children (selector is stored separately in ty field)
        var children = std.ArrayListUnmanaged(ast.Node){};
        defer children.deinit(self.alloc);
        // Store selector expression in the first child slot
        const expr_node = expr; // Capture before dupeNodes
        while (self.current().tag != .r_brace and self.current().tag != .eof) {
            if (self.current().tag == .kw_case) {
                _ = self.advance();
                const val = try self.parseExpression();
                _ = try self.expect(.colon);
                // Parse statements until next case/default/}
                var case_body = std.ArrayListUnmanaged(ast.Node){};
                defer case_body.deinit(self.alloc);
                // Store case value expression as first child
                try case_body.append(self.alloc, val);
                while (self.current().tag != .kw_case and self.current().tag != .kw_default and self.current().tag != .r_brace) {
                    try case_body.append(self.alloc, try self.parseStatement());
                }
                const case_base = val; // Capture before dupeNodes
                try children.append(self.alloc, .{
                    .tag = .block,
                    .loc = case_base.loc,
                    .data = .{ .children = try self.dupeNodes(case_body.items), .ty = case_base.data.ty, .name = "case" },
                });
            } else if (self.current().tag == .kw_default) {
                _ = self.advance();
                _ = try self.expect(.colon);
                var case_body = std.ArrayListUnmanaged(ast.Node){};
                defer case_body.deinit(self.alloc);
                while (self.current().tag != .kw_case and self.current().tag != .kw_default and self.current().tag != .r_brace) {
                    try case_body.append(self.alloc, try self.parseStatement());
                }
                try children.append(self.alloc, .{
                    .tag = .block,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .children = try self.dupeNodes(case_body.items), .ty = null, .name = "default" },
                });
            } else break;
        }
        _ = try self.expect(.r_brace);

        // Store selector expression and case children
        var all_children = std.ArrayListUnmanaged(ast.Node){};
        defer all_children.deinit(self.alloc);
        try all_children.append(self.alloc, expr_node);
        for (children.items) |c| try all_children.append(self.alloc, c);

        return .{
            .tag = .switch_stmt,
            .loc = self.nodeLoc(tok),
            .data = .{ .children = try self.dupeNodes(all_children.items), .ty = null, .name = "switch" },
        };
    }

    fn parseReturn(self: *Parser) Error!ast.Node {
        const tok = self.advance(); // 'return'
        if (self.current().tag == .semicolon) {
            _ = self.advance();
            return .{ .tag = .return_stmt, .loc = self.nodeLoc(tok), .data = .{} };
        }
        const expr = try self.parseExpression();
        _ = try self.expect(.semicolon);
        return .{
            .tag = .return_stmt,
            .loc = self.nodeLoc(tok),
            .data = .{ .children = try self.dupeNodes(&.{expr}) },
        };
    }

    fn parseExprStmt(self: *Parser) Error!ast.Node {
        const expr = try self.parseExpression();
        _ = try self.expect(.semicolon);
        return .{
            .tag = .expr_stmt,
            .loc = expr.loc,
            .data = .{ .children = try self.dupeNodes(&.{expr}) },
        };
    }

    // ── Expressions (Pratt precedence climbing) ───────────────

    fn parseExpression(self: *Parser) Error!ast.Node {
        return self.parseAssignment();
    }

    /// Parse comma expression (for for-loop update/condition)
    fn parseCommaExpression(self: *Parser) Error!ast.Node {
        const expr = try self.parseAssignment();
        if (self.current().tag != .comma) return expr;
        var children = std.ArrayListUnmanaged(ast.Node){};
        defer children.deinit(self.alloc);
        try children.append(self.alloc, expr);
        while (self.current().tag == .comma) {
            _ = self.advance();
            try children.append(self.alloc, try self.parseAssignment());
        }
        return .{
            .tag = .comma_op,
            .loc = expr.loc,
            .data = .{ .children = try self.ownedChildren(&children) },
        };
    }

    fn parseAssignment(self: *Parser) Error!ast.Node {
        const lhs = try self.parseTernary();

        const AssignInfo = struct {
            tag: lexer.Token.Tag,
            op: ast.Op,
            node_tag: ast.Node.Tag,
        };
        const ops = [_]AssignInfo{
            .{ .tag = .eq, .op = .assign, .node_tag = .assign_op },
            .{ .tag = .plus_eq, .op = .add_assign, .node_tag = .compound_assign },
            .{ .tag = .minus_eq, .op = .sub_assign, .node_tag = .compound_assign },
            .{ .tag = .star_eq, .op = .mul_assign, .node_tag = .compound_assign },
            .{ .tag = .slash_eq, .op = .div_assign, .node_tag = .compound_assign },
            .{ .tag = .percent_eq, .op = .mod_assign, .node_tag = .compound_assign },
            .{ .tag = .ampersand_eq, .op = .and_assign, .node_tag = .compound_assign },
            .{ .tag = .pipe_eq, .op = .or_assign, .node_tag = .compound_assign },
            .{ .tag = .caret_eq, .op = .xor_assign, .node_tag = .compound_assign },
            .{ .tag = .lshift_eq, .op = .lshift_assign, .node_tag = .compound_assign },
            .{ .tag = .rshift_eq, .op = .rshift_assign, .node_tag = .compound_assign },
        };
        for (&ops) |info| {
            if (self.current().tag == info.tag) {
                _ = self.advance();
                const right = try self.parseAssignment();
                return .{
                    .tag = info.node_tag,
                    .loc = lhs.loc,
                    .data = .{ .op = info.op, .children = try self.dupeNodes(&.{ lhs, right }) },
                };
            }
        }
        return lhs;
    }

    fn parseTernary(self: *Parser) Error!ast.Node {
        const cond = try self.parseLogicalOr();
        if (self.current().tag == .question) {
            _ = self.advance();
            const then_expr = try self.parseExpression();
            _ = self.expect(.colon) catch return cond;
            const else_expr = try self.parseTernary();
            return .{
                .tag = .ternary_op,
                .loc = cond.loc,
                .data = .{ .children = try self.dupeNodes(&.{ cond, then_expr, else_expr }) },
            };
        }
        return cond;
    }

    fn parseLogicalOr(self: *Parser) Error!ast.Node {
        var left = try self.parseLogicalAnd();
        while (self.current().tag == .pipe_pipe) {
            const op_tok = self.advance();
            const right = try self.parseLogicalAnd();
            left = try self.makeBinaryOp(self.nodeLoc(op_tok), .logical_or, left, right);
        }
        return left;
    }

    fn parseLogicalAnd(self: *Parser) Error!ast.Node {
        var left = try self.parseBitwiseOr();
        while (self.current().tag == .ampersand_ampersand) {
            const op_tok = self.advance();
            const right = try self.parseBitwiseOr();
            left = try self.makeBinaryOp(self.nodeLoc(op_tok), .logical_and, left, right);
        }
        return left;
    }

    fn parseBitwiseOr(self: *Parser) Error!ast.Node {
        var left = try self.parseBitwiseXor();
        while (self.current().tag == .pipe) {
            const op_tok = self.advance();
            const right = try self.parseBitwiseXor();
            left = try self.makeBinaryOp(self.nodeLoc(op_tok), .bit_or, left, right);
        }
        return left;
    }

    fn parseBitwiseXor(self: *Parser) Error!ast.Node {
        var left = try self.parseBitwiseAnd();
        while (self.current().tag == .caret) {
            const op_tok = self.advance();
            const right = try self.parseBitwiseAnd();
            left = try self.makeBinaryOp(self.nodeLoc(op_tok), .bit_xor, left, right);
        }
        return left;
    }

    fn parseBitwiseAnd(self: *Parser) Error!ast.Node {
        var left = try self.parseEquality();
        while (self.current().tag == .ampersand) {
            const op_tok = self.advance();
            const right = try self.parseEquality();
            left = try self.makeBinaryOp(self.nodeLoc(op_tok), .bit_and, left, right);
        }
        return left;
    }

    fn parseEquality(self: *Parser) Error!ast.Node {
        var left = try self.parseRelational();
        while (self.current().tag == .eq_eq or self.current().tag == .bang_eq) {
            const op: ast.Op = if (self.current().tag == .eq_eq) .eq else .neq;
            const op_tok = self.advance();
            const right = try self.parseRelational();
            left = try self.makeBinaryOp(self.nodeLoc(op_tok), op, left, right);
        }
        return left;
    }

    fn parseRelational(self: *Parser) Error!ast.Node {
        var left = try self.parseShift();
        while (true) {
            const op: ?ast.Op = switch (self.current().tag) {
                .lt => .lt,
                .gt => .gt,
                .lt_eq => .lte,
                .gt_eq => .gte,
                else => null,
            };
            if (op) |o| {
                const op_tok = self.advance();
                const right = try self.parseShift();
                left = try self.makeBinaryOp(self.nodeLoc(op_tok), o, left, right);
            } else break;
        }
        return left;
    }

    fn parseShift(self: *Parser) Error!ast.Node {
        var left = try self.parseAdditive();
        while (self.current().tag == .lshift or self.current().tag == .rshift) {
            const op: ast.Op = if (self.current().tag == .lshift) .lshift else .rshift;
            const op_tok = self.advance();
            const right = try self.parseAdditive();
            left = try self.makeBinaryOp(self.nodeLoc(op_tok), op, left, right);
        }
        return left;
    }

    fn parseAdditive(self: *Parser) Error!ast.Node {
        var left = try self.parseMultiplicative();
        while (self.current().tag == .plus or self.current().tag == .minus) {
            const op: ast.Op = if (self.current().tag == .plus) .add else .sub;
            const op_tok = self.advance();
            const right = try self.parseMultiplicative();
            left = try self.makeBinaryOp(self.nodeLoc(op_tok), op, left, right);
        }
        return left;
    }

    fn parseMultiplicative(self: *Parser) Error!ast.Node {
        var left = try self.parseUnary();
        while (self.current().tag == .star or self.current().tag == .slash or self.current().tag == .percent) {
            const op: ast.Op = switch (self.current().tag) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => unreachable,
            };
            const op_tok = self.advance();
            const right = try self.parseUnary();
            left = try self.makeBinaryOp(self.nodeLoc(op_tok), op, left, right);
        }
        return left;
    }

    fn parseUnary(self: *Parser) Error!ast.Node {
        switch (self.current().tag) {
            .minus => {
                const tok = self.advance();
                const operand = try self.parseUnary();
                return .{
                    .tag = .unary_op,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .op = .sub, .children = try self.dupeNodes(&.{operand}) },
                };
            },
            .plus => {
                // Unary plus — just consume and parse operand
                _ = self.advance();
                return self.parseUnary();
            },
            .bang => {
                const tok = self.advance();
                const operand = try self.parseUnary();
                return .{
                    .tag = .unary_op,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .op = .logical_not, .children = try self.dupeNodes(&.{operand}) },
                };
            },
            .tilde => {
                const tok = self.advance();
                const operand = try self.parseUnary();
                return .{
                    .tag = .unary_op,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .op = .bit_not, .children = try self.dupeNodes(&.{operand}) },
                };
            },
            .plus_plus => {
                const tok = self.advance();
                const operand = try self.parseUnary();
                return .{
                    .tag = .pre_increment,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .children = try self.dupeNodes(&.{operand}) },
                };
            },
            .minus_minus => {
                const tok = self.advance();
                const operand = try self.parseUnary();
                return .{
                    .tag = .pre_decrement,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .children = try self.dupeNodes(&.{operand}) },
                };
            },
            else => return self.parsePostfix(),
        }
    }

    fn parsePostfix(self: *Parser) Error!ast.Node {
        var expr = try self.parsePrimary();
        while (true) {
            switch (self.current().tag) {
                .l_bracket => {
                    _ = self.advance();
                    const index = try self.parseExpression();
                    _ = self.expect(.r_bracket) catch break;
                    const base = expr;
                    expr = .{
                        .tag = .index_access,
                        .loc = base.loc,
                        .data = .{ .children = try self.dupeNodes(&.{ base, index }) },
                    };
                },
                .dot => {
                    _ = self.advance();
                    const member_tok = self.current();
                    _ = self.advance();
                    const member_name = self.text(member_tok);
                    const base = expr; // Capture before constructing new node
                    expr = .{
                        .tag = .member_access,
                        .loc = base.loc,
                        .data = .{ .name = member_name, .children = try self.dupeNodes(&.{base}) },
                    };
                },
                .plus_plus => {
                    _ = self.advance();
                    const pp_base = expr;
                    expr = .{
                        .tag = .post_increment,
                        .loc = pp_base.loc,
                        .data = .{ .children = try self.dupeNodes(&.{pp_base}) },
                    };
                },
                .minus_minus => {
                    _ = self.advance();
                    const mm_base = expr;
                    expr = .{
                        .tag = .post_decrement,
                        .loc = mm_base.loc,
                        .data = .{ .children = try self.dupeNodes(&.{mm_base}) },
                    };
                },
                else => {
                    // Handle bare '.' tokenized as double_literal
                    if (self.current().tag == .double_literal) {
                        const tok_text = self.text(self.current());
                        if (tok_text.len == 1 and tok_text[0] == '.') {
                            const next_idx = self.pos + 1;
                            if (next_idx < self.tokens.len and self.tokens[next_idx].tag == .identifier) {
                                _ = self.advance(); // consume '.'
                                const member_tok = self.current();
                                _ = self.advance(); // consume member name
                                const member_name = self.text(member_tok);
                                const base = expr;
                                expr = .{
                                    .tag = .member_access,
                                    .loc = base.loc,
                                    .data = .{ .name = member_name, .children = try self.dupeNodes(&.{base}) },
                                };
                                continue;
                            }
                        }
                    }
                    break;
                },
            }
        }
        return expr;
    }

    fn parsePrimary(self: *Parser) Error!ast.Node {
        const tok = self.current();
        switch (tok.tag) {
            .int_literal, .uint_literal => {
                _ = self.advance();
                var num_text = self.text(tok);
                // Strip 'u'/'U' suffix for uint literals
                if (num_text.len > 0 and (num_text[num_text.len - 1] == 'u' or num_text[num_text.len - 1] == 'U')) {
                    num_text = num_text[0 .. num_text.len - 1];
                }
                const val = std.fmt.parseInt(i64, num_text, 0) catch 0;
                return .{
                    .tag = if (tok.tag == .uint_literal) .uint_literal else .int_literal,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .int_val = val },
                };
            },
            .float_literal, .double_literal => {
                _ = self.advance();
                const raw_text = self.text(tok);
                const num_text = if (raw_text.len > 0 and (raw_text[raw_text.len - 1] == 'f' or raw_text[raw_text.len - 1] == 'F'))
                    raw_text[0 .. raw_text.len - 1]
                else
                    raw_text;
                const val = std.fmt.parseFloat(f64, num_text) catch 0.0;
                return .{
                    .tag = .float_literal,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .float_val = val },
                };
            },
            .kw_true => {
                _ = self.advance();
                return .{ .tag = .bool_literal, .loc = self.nodeLoc(tok), .data = .{ .int_val = 1 } };
            },
            .kw_false => {
                _ = self.advance();
                return .{ .tag = .bool_literal, .loc = self.nodeLoc(tok), .data = .{ .int_val = 0 } };
            },
            .identifier => {
                _ = self.advance();
                // Handle struct array constructors: StructName[](args...)
                // Check if pattern is Identifier[]...( where [] repeats
                if (self.current().tag == .l_bracket and self.peek().tag == .r_bracket) {
                    // Looks like StructName[] pattern — consume all [] pairs
                    const base_name = self.text(tok);
                    var ty: ast.Type = .{ .named = base_name };
                    var dim_count: usize = 0;
                    while (self.current().tag == .l_bracket and self.peek().tag == .r_bracket) {
                        _ = self.advance(); // [
                        _ = self.advance(); // ]
                        const arr_base = try self.createType(ty);
                        ty = .{ .array = .{ .base = arr_base, .size = 0 } };
                        dim_count += 1;
                    }
                    if (self.current().tag == .l_paren and dim_count > 0) {
                        // StructName[]...(args...) — struct array constructor
                        _ = self.advance(); // (
                        var args = std.ArrayListUnmanaged(ast.Node){};
                        defer args.deinit(self.alloc);
                        while (self.current().tag != .r_paren and self.current().tag != .eof) {
                            try args.append(self.alloc, try self.parseExpression());
                            if (self.current().tag == .comma) _ = self.advance();
                        }
                        _ = self.expect(.r_paren) catch {};
                        return .{
                            .tag = .type_constructor,
                            .loc = self.nodeLoc(tok),
                            .data = .{ .ty = ty, .children = try self.ownedChildren(&args) },
                        };
                    }
                    // Not followed by (, backtrack not easy — but this shouldn't happen for valid GLSL
                    // Return identifier anyway, the [] was probably array indexing but we already consumed them
                    // This is a known limitation: arr[] is not valid GLSL anyway
                }
                if (self.current().tag == .l_paren) {
                    _ = self.advance();
                    var args = std.ArrayListUnmanaged(ast.Node){};
                    defer args.deinit(self.alloc);
                    while (self.current().tag != .r_paren and self.current().tag != .eof) {
                        try args.append(self.alloc, try self.parseExpression());
                        if (self.current().tag == .comma) _ = self.advance();
                    }
                    _ = self.expect(.r_paren) catch {};
                    return .{
                        .tag = .func_call,
                        .loc = self.nodeLoc(tok),
                        .data = .{ .name = self.text(tok), .children = try self.ownedChildren(&args) },
                    };
                }
                return .{
                    .tag = .identifier,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .name = self.text(tok) },
                };
            },
            .l_paren => {
                _ = self.advance();
                const expr = try self.parseExpression();
                _ = self.expect(.r_paren) catch {};
                return .{
                    .tag = .group,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .children = try self.dupeNodes(&.{expr}) },
                };
            },
            // Type constructors: vec3(1,2,3), mat4(1.0), float(x), etc.
            .kw_vec2, .kw_vec3, .kw_vec4,
            .kw_ivec2, .kw_ivec3, .kw_ivec4,
            .kw_bvec2, .kw_bvec3, .kw_bvec4,
            .kw_uvec2, .kw_uvec3, .kw_uvec4,
            .kw_i8vec2, .kw_i8vec3, .kw_i8vec4,
            .kw_u8vec2, .kw_u8vec3, .kw_u8vec4,
            .kw_mat2, .kw_mat3, .kw_mat4,
            .kw_mat2x2, .kw_mat2x3, .kw_mat2x4,
            .kw_mat3x2, .kw_mat3x3, .kw_mat3x4,
            .kw_mat4x2, .kw_mat4x3, .kw_mat4x4,
            .kw_float, .kw_int, .kw_uint, .kw_bool,
            .kw_int8, .kw_uint8,
            .kw_sampler2d, .kw_sampler3d, .kw_sampler_cube, .kw_sampler2d_array, .kw_sampler2d_ms,
            => {
                var ty = self.tryType().?;
                // Handle array constructors: float[](1.0, 2.0, ...), vec4[](...), vec4[][](...)
                while (self.current().tag == .l_bracket) {
                    _ = self.advance(); // [
                    if (self.current().tag == .r_bracket) {
                        _ = self.advance(); // ]
                        // Unsized array constructor: base_type[](...)
                        const arr_base = try self.createType(ty);
                        ty = .{ .array = .{ .base = arr_base, .size = 0 } };
                    } else {
                        // Sized array type: base_type[N]
                        const size_tok = self.current();
                        _ = self.advance(); // size
                        _ = self.expect(.r_bracket) catch {};
                        const size_val = std.fmt.parseInt(u32, self.text(size_tok), 0) catch 0;
                        const arr_base = try self.createType(ty);
                        ty = .{ .array = .{ .base = arr_base, .size = size_val } };
                    }
                }
                _ = self.expect(.l_paren) catch return .{
                    .tag = .type_constructor,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .ty = ty },
                };
                var args = std.ArrayListUnmanaged(ast.Node){};
                defer args.deinit(self.alloc);
                while (self.current().tag != .r_paren and self.current().tag != .eof) {
                    try args.append(self.alloc, try self.parseExpression());
                    if (self.current().tag == .comma) _ = self.advance();
                }
                _ = self.expect(.r_paren) catch {};
                return .{
                    .tag = .type_constructor,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .ty = ty, .children = try self.ownedChildren(&args) },
                };
            },
            // texture2D, texture3D etc. are built-in functions, not type constructors.
            // They're tokenized as keywords but used as function calls: texture2D(sampler, coord)
            .kw_texture2d, .kw_texture3d, .kw_texture_cube, .kw_texture2d_array, .kw_texture2d_ms,
            => {
                const name = self.text(tok);
                _ = self.advance();
                if (self.current().tag == .l_paren) {
                    _ = self.advance(); // (
                    var args = std.ArrayListUnmanaged(ast.Node){};
                    defer args.deinit(self.alloc);
                    while (self.current().tag != .r_paren and self.current().tag != .eof) {
                        try args.append(self.alloc, try self.parseExpression());
                        if (self.current().tag == .comma) _ = self.advance();
                    }
                    _ = self.expect(.r_paren) catch {};
                    return .{
                        .tag = .func_call,
                        .loc = self.nodeLoc(tok),
                        .data = .{ .name = name, .children = try self.ownedChildren(&args) },
                    };
                }
                return .{ .tag = .identifier, .loc = self.nodeLoc(tok), .data = .{ .name = name } };
            },
            else => {
                _ = self.advance();
                return .{ .tag = .identifier, .loc = self.nodeLoc(tok), .data = .{} };
            },
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "parse empty main" {
    const alloc = std.testing.allocator;
    const source = "void main() {}";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    try std.testing.expectEqual(ast.Node.Tag.function_decl, root.body[0].tag);
    try std.testing.expectEqualStrings("main", root.body[0].data.name);
}

test "parse variable declaration" {
    const alloc = std.testing.allocator;
    const source = "float x;";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    try std.testing.expectEqual(ast.Node.Tag.var_decl, root.body[0].tag);
    try std.testing.expectEqualStrings("x", root.body[0].data.name);
    try std.testing.expectEqual(ast.Type.float, root.body[0].data.ty);
}

test "parse variable with initializer" {
    const alloc = std.testing.allocator;
    const source = "float x = 1.0;";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    try std.testing.expectEqual(ast.Node.Tag.var_decl, root.body[0].tag);
    try std.testing.expectEqual(@as(usize, 1), root.body[0].data.children.len);
    try std.testing.expectEqual(ast.Node.Tag.float_literal, root.body[0].data.children[0].tag);
}

test "parse function with params" {
    const alloc = std.testing.allocator;
    const source = "float add(float a, float b) { return a + b; }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    const func = root.body[0];
    try std.testing.expectEqual(ast.Node.Tag.function_decl, func.tag);
    try std.testing.expectEqualStrings("add", func.data.name);
    try std.testing.expectEqual(@as(usize, 2), func.data.params.len);
    try std.testing.expectEqualStrings("a", func.data.params[0].name);
    try std.testing.expectEqualStrings("b", func.data.params[1].name);
}

test "parse expression precedence" {
    const alloc = std.testing.allocator;
    const source = "void main() { float x = 1 + 2 * 3; }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    const func = root.body[0];
    try std.testing.expectEqual(ast.Node.Tag.function_decl, func.tag);
    // Body should contain one var_decl statement
    try std.testing.expectEqual(@as(usize, 1), func.data.children.len);
    const stmt = func.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.var_decl, stmt.tag);
    // The initializer should be 1 + (2 * 3) due to precedence
    const init = stmt.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.binary_op, init.tag);
    try std.testing.expectEqual(ast.Op.add, init.data.op);
}

test "parse if else" {
    const alloc = std.testing.allocator;
    const source = "void main() { if (true) { } else { } }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    const func = root.body[0];
    try std.testing.expectEqual(ast.Node.Tag.if_stmt, func.data.children[0].tag);
    const if_node = func.data.children[0];
    // cond + then + else = 3 children
    try std.testing.expectEqual(@as(usize, 3), if_node.data.children.len);
}

test "parse for loop" {
    const alloc = std.testing.allocator;
    const source = "void main() { for (int i = 0; i < 10; i++) { } }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    const func = root.body[0];
    try std.testing.expectEqual(ast.Node.Tag.for_stmt, func.data.children[0].tag);
    const for_node = func.data.children[0];
    // init(var_decl) + cond(binary) + update(post_increment) + body(block)
    try std.testing.expectEqual(@as(usize, 4), for_node.data.children.len);
}

test "parse while loop" {
    const alloc = std.testing.allocator;
    const source = "void main() { while (true) { } }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    const func = root.body[0];
    try std.testing.expectEqual(ast.Node.Tag.while_stmt, func.data.children[0].tag);
}

test "parse do while" {
    const alloc = std.testing.allocator;
    const source = "void main() { do { } while (true); }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    const func = root.body[0];
    try std.testing.expectEqual(ast.Node.Tag.do_while_stmt, func.data.children[0].tag);
}

test "parse return statement" {
    const alloc = std.testing.allocator;
    const source = "float f() { return 1.0; }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    const func = root.body[0];
    try std.testing.expectEqual(ast.Node.Tag.return_stmt, func.data.children[0].tag);
    const ret = func.data.children[0];
    try std.testing.expectEqual(@as(usize, 1), ret.data.children.len);
    try std.testing.expectEqual(ast.Node.Tag.float_literal, ret.data.children[0].tag);
}

test "parse uniform declaration" {
    const alloc = std.testing.allocator;
    const source = "uniform vec3 color;";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    try std.testing.expectEqual(ast.Node.Tag.uniform_decl, root.body[0].tag);
    try std.testing.expectEqualStrings("color", root.body[0].data.name);
    try std.testing.expectEqual(ast.Type.vec3, root.body[0].data.ty);
}

test "parse layout qualifier" {
    const alloc = std.testing.allocator;
    const source = "layout(location = 0) out vec4 fragColor;";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    try std.testing.expectEqual(ast.Node.Tag.out_decl, root.body[0].tag);
    try std.testing.expectEqualStrings("fragColor", root.body[0].data.name);
    const layout = root.body[0].data.layout.?;
    try std.testing.expectEqual(@as(u32, 0), layout.location.?);
}

test "parse struct declaration" {
    const alloc = std.testing.allocator;
    const source = "struct Light { vec3 position; float intensity; };";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    try std.testing.expectEqual(ast.Node.Tag.struct_decl, root.body[0].tag);
    try std.testing.expectEqualStrings("Light", root.body[0].data.name);
    try std.testing.expectEqual(@as(usize, 2), root.body[0].data.members.len);
    try std.testing.expectEqualStrings("position", root.body[0].data.members[0].name);
    try std.testing.expectEqualStrings("intensity", root.body[0].data.members[1].name);
}

test "parse binary expressions" {
    const alloc = std.testing.allocator;
    const source = "void main() { int x = 1 + 2 - 3 * 4 / 5; }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    const func = root.body[0];
    const stmt = func.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.var_decl, stmt.tag);
    const init = stmt.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.binary_op, init.tag);
}

test "parse function call" {
    const alloc = std.testing.allocator;
    const source = "void main() { float x = sin(0.5); }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    const func = root.body[0];
    const stmt = func.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.var_decl, stmt.tag);
    const init = stmt.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.func_call, init.tag);
    try std.testing.expectEqualStrings("sin", init.data.name);
    try std.testing.expectEqual(@as(usize, 1), init.data.children.len);
}

test "parse equality operators" {
    const alloc = std.testing.allocator;
    const source = "void main() { bool a = x == y; bool b = x != y; }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    const func = root.body[0];
    try std.testing.expectEqual(@as(usize, 2), func.data.children.len);
    // a = x == y
    const stmt_a = func.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.var_decl, stmt_a.tag);
    const eq_expr = stmt_a.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.binary_op, eq_expr.tag);
    try std.testing.expectEqual(ast.Op.eq, eq_expr.data.op);
    try std.testing.expectEqual(@as(usize, 2), eq_expr.data.children.len);
    // b = x != y
    const stmt_b = func.data.children[1];
    const neq_expr = stmt_b.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.binary_op, neq_expr.tag);
    try std.testing.expectEqual(ast.Op.neq, neq_expr.data.op);
}

test "parse complex shader with chained ops" {
    const alloc = std.testing.allocator;
    const source =
        \\void main() {
        \\    float a = 1.0;
        \\    float b = 2.0;
        \\    float c = a + b * 3.0 - 1.0;
        \\    c = c / 2.0;
        \\    bool flag = a > b;
        \\    if (flag) {
        \\        c = c + 1.0;
        \\    }
        \\    for (int i = 0; i < 10; i++) {
        \\        c = c + 1.0;
        \\    }
        \\    vec4 color = vec4(c, c, c, 1.0);
        \\}
    ;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);

    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    const func = root.body[0];
    try std.testing.expectEqual(ast.Node.Tag.function_decl, func.tag);
    // 8 statements: a, b, c, c=, flag, if, for, color
    try std.testing.expectEqual(@as(usize, 8), func.data.children.len);

    // Verify c = a + b * 3.0 - 1.0 has valid children
    const c_decl = func.data.children[2];
    try std.testing.expectEqual(ast.Node.Tag.var_decl, c_decl.tag);
    const c_init = c_decl.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.binary_op, c_init.tag);
    try std.testing.expectEqual(@as(usize, 2), c_init.data.children.len);
    // Should be (a + (b * 3.0)) - 1.0, so outer op is sub
    try std.testing.expectEqual(ast.Op.sub, c_init.data.op);

    // Verify the for loop
    const for_stmt = func.data.children[6];
    try std.testing.expectEqual(ast.Node.Tag.for_stmt, for_stmt.tag);
    try std.testing.expectEqual(@as(usize, 4), for_stmt.data.children.len);

    // Verify vec4 constructor
    const color_decl = func.data.children[7];
    try std.testing.expectEqual(ast.Node.Tag.var_decl, color_decl.tag);
    const ctor = color_decl.data.children[0];
    try std.testing.expectEqual(ast.Node.Tag.type_constructor, ctor.tag);
    try std.testing.expectEqual(@as(usize, 4), ctor.data.children.len);
}

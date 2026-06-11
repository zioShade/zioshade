// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const semantic = @import("semantic.zig");

pub const Error = error{
    OutOfMemory,
    UnexpectedToken,
};

pub fn parse(alloc: std.mem.Allocator, source: [:0]const u8, tokens: []const lexer.Token) Error!ast.Root {
    // Clear the error-context threadlocals so a stale message from a previous
    // compile (e.g. this parse's nested-function detail) can never bleed into a
    // later, unrelated parse failure. `recordErrorLoc` still sets line/column.
    semantic.last_error_ctx = "";
    semantic.last_error_inner = "";

    var p = Parser{
        .alloc = alloc,
        .source = source,
        .tokens = tokens,
        .pos = 0,
        .struct_names = .{},
    };

    var body = std.ArrayListUnmanaged(ast.Node).empty;
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

    // Fail loudly if the parser saw an unambiguously-broken construct (e.g. a
    // nested function definition). Returning here lets the `errdefer` above free
    // `body`, `struct_names`, and the heap-tracked children/types — exactly the
    // cleanup the success path does below.
    if (p.fatal_parse_error) return error.UnexpectedToken;

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
    heap_types: std.ArrayListUnmanaged(*ast.Type) = .empty,
    heap_children: std.ArrayListUnmanaged([]const ast.Node) = .empty,
    /// Set when the parser encounters a construct that is *unambiguously*
    /// invalid GLSL (currently: a nested function definition inside a function
    /// body — see `parseLocalVarDecl`). Error recovery still runs so we can skip
    /// the malformed text, but a set flag makes `parse()` fail loudly at the end
    /// so a genuinely-broken shader can never reach codegen as a hollow module.
    ///
    /// This is deliberately NOT set on every `synchronize()` recovery: the
    /// parser legitimately recovers from many *valid-but-unsupported* constructs
    /// (precision qualifiers on locals, `double`/`int64` types, comment
    /// line-continuations, …), and failing on those would reject ~700 valid
    /// conformance shaders. We only fail loudly where we can be certain the
    /// source itself is broken.
    ///
    /// Scope note: this catches the one statement shape that is *unambiguously*
    /// invalid (a nested function definition). Other genuinely-broken statements
    /// (e.g. `float x = ;`) still recover silently, because the parser cannot
    /// reliably tell "broken" from "valid-but-unsupported" without a full
    /// grammar + oracle. Widening the net is future work. The error location is
    /// captured via `recordErrorLoc`.
    fatal_parse_error: bool = false,

    // ── Navigation ────────────────────────────────────────────

    /// Record the current token's location as the error position.
    fn recordErrorLoc(self: *Parser) void {
        // Once a fatal parse error is pinned, keep its location: error recovery
        // (synchronize) keeps scanning and would otherwise overwrite the pin
        // with a later, unrelated recovery position.
        if (self.fatal_parse_error) return;
        const tok = self.current();
        semantic.last_error_line = tok.loc.line;
        semantic.last_error_column = tok.loc.column;
    }

    /// Assuming `current()` is the `(` that opens a parameter list at statement
    /// scope, scan to the matching `)` and report whether a `{` body follows.
    /// `type identifier ( … ) {` is a nested function *definition* (illegal in
    /// GLSL); `type identifier ( … ) ;` is a local prototype (legal — glslang
    /// accepts it). Pure lookahead; does not advance the parser.
    fn nestedFunctionBodyFollows(self: *Parser) bool {
        var depth: usize = 0;
        var i = self.pos;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].tag) {
                .l_paren => depth += 1,
                .r_paren => {
                    depth -= 1;
                    if (depth == 0) {
                        const j = i + 1;
                        return j < self.tokens.len and self.tokens[j].tag == .l_brace;
                    }
                },
                .eof => return false,
                else => {},
            }
        }
        return false;
    }

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
        if (tok.tag != tag) {
            self.recordErrorLoc();
            return error.UnexpectedToken;
        }
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
            .kw_isampler_buffer, .kw_usampler_buffer,
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

    /// Returns true when `name` is a GLSL 64-bit type keyword that the lexer does not
    /// map to a dedicated token (because glslpp does not implement 64-bit types).
    /// Recognizing these names lets the parser build a proper var_decl node so that
    /// the semantic layer can emit a clear "unsupported 64-bit type" honest error
    /// instead of a misleading UndeclaredIdentifier for the variable name that follows.
    fn is64BitTypeName(name: []const u8) bool {
        const names64 = [_][]const u8{
            "double",
            "dvec2", "dvec3", "dvec4",
            "dmat2", "dmat3", "dmat4",
            "dmat2x2", "dmat2x3", "dmat2x4",
            "dmat3x2", "dmat3x3", "dmat3x4",
            "dmat4x2", "dmat4x3", "dmat4x4",
            "int64_t", "uint64_t",
            "i64vec2", "i64vec3", "i64vec4",
            "u64vec2", "u64vec3", "u64vec4",
        };
        for (names64) |n| {
            if (std.mem.eql(u8, name, n)) return true;
        }
        return false;
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

        const ty = self.tryType() orelse {
            self.recordErrorLoc();
            return error.UnexpectedToken;
        };
        // Handle array dimensions on type (e.g., vec4[2] for function return types)
        var final_ty = ty;
        if (self.current().tag == .l_bracket) {
            // Parse array dimensions
            var arr_dims: std.ArrayListUnmanaged(u32) = .empty;
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
        if (name_tok.tag != .identifier) {
            self.recordErrorLoc();
            return error.UnexpectedToken;
        }
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
                .identifier => {
                    const ident_text = self.text(self.current());
                    if (std.mem.eql(u8, ident_text, "taskPayloadSharedEXT")) {
                        q.is_task_payload_shared = true;
                        _ = self.advance(); found = true;
                    } else if (std.mem.eql(u8, ident_text, "rayPayloadEXT")) {
                        q.is_ray_payload = true;
                        _ = self.advance(); found = true;
                    } else if (std.mem.eql(u8, ident_text, "incomingRayPayloadEXT")) {
                        q.is_incoming_ray_payload = true;
                        _ = self.advance(); found = true;
                    } else if (std.mem.eql(u8, ident_text, "hitAttributeEXT")) {
                        q.is_hit_attribute = true;
                        _ = self.advance(); found = true;
                    } else if (std.mem.eql(u8, ident_text, "callableDataEXT")) {
                        q.is_callable_data = true;
                        _ = self.advance(); found = true;
                    } else if (std.mem.eql(u8, ident_text, "incomingCallableDataEXT")) {
                        q.is_incoming_callable_data = true;
                        _ = self.advance(); found = true;
                    } else if (std.mem.eql(u8, ident_text, "perprimitiveEXT")) {
                        // GL_EXT_mesh_shader: marks an `out` variable as
                        // per-primitive rather than per-vertex.
                        q.is_perprimitive_ext = true;
                        _ = self.advance(); found = true;
                    } else if (std.mem.eql(u8, ident_text, "pervertexEXT")) {
                        // GL_EXT_fragment_shader_barycentric: marks a fragment
                        // `in` as a per-vertex array (PerVertexKHR decoration).
                        q.is_pervertex_ext = true;
                        _ = self.advance(); found = true;
                    } else if (std.mem.eql(u8, ident_text, "pervertexNV")) {
                        // GL_NV_fragment_shader_barycentric: NV spelling of the
                        // same per-vertex array qualifier.
                        q.is_pervertex_nv = true;
                        _ = self.advance(); found = true;
                    } else break;
                },
                else => break,
            }
        }
        return if (found) q else null;
    }

    /// Map a GLSL `layout(...)` bare identifier to its SPIR-V image-format
    /// enum value. Returns `null` if the identifier isn't a known format
    /// qualifier — caller falls through to the other layout-identifier
    /// branches. All 40 SPIR-V Image Format entries are recognized so reflection
    /// can report any qualifier the GLSL spec allows.
    fn parseImageFormatIdent(text_in: []const u8) ?ast.ImageFormat {
        const map = .{
            .{ "rgba32f", ast.ImageFormat.rgba32f },
            .{ "rgba16f", ast.ImageFormat.rgba16f },
            .{ "r32f", ast.ImageFormat.r32f },
            .{ "rgba8", ast.ImageFormat.rgba8 },
            .{ "rgba8_snorm", ast.ImageFormat.rgba8_snorm },
            .{ "rg32f", ast.ImageFormat.rg32f },
            .{ "rg16f", ast.ImageFormat.rg16f },
            .{ "r11f_g11f_b10f", ast.ImageFormat.r11f_g11f_b10f },
            .{ "r16f", ast.ImageFormat.r16f },
            .{ "rgba16", ast.ImageFormat.rgba16 },
            .{ "rgb10_a2", ast.ImageFormat.rgb10_a2 },
            .{ "rg16", ast.ImageFormat.rg16 },
            .{ "rg8", ast.ImageFormat.rg8 },
            .{ "r16", ast.ImageFormat.r16 },
            .{ "r8", ast.ImageFormat.r8 },
            .{ "rgba16_snorm", ast.ImageFormat.rgba16_snorm },
            .{ "rg16_snorm", ast.ImageFormat.rg16_snorm },
            .{ "rg8_snorm", ast.ImageFormat.rg8_snorm },
            .{ "r16_snorm", ast.ImageFormat.r16_snorm },
            .{ "r8_snorm", ast.ImageFormat.r8_snorm },
            .{ "rgba32i", ast.ImageFormat.rgba32i },
            .{ "rgba16i", ast.ImageFormat.rgba16i },
            .{ "rgba8i", ast.ImageFormat.rgba8i },
            .{ "r32i", ast.ImageFormat.r32i },
            .{ "rg32i", ast.ImageFormat.rg32i },
            .{ "rg16i", ast.ImageFormat.rg16i },
            .{ "rg8i", ast.ImageFormat.rg8i },
            .{ "r16i", ast.ImageFormat.r16i },
            .{ "r8i", ast.ImageFormat.r8i },
            .{ "rgba32ui", ast.ImageFormat.rgba32ui },
            .{ "rgba16ui", ast.ImageFormat.rgba16ui },
            .{ "rgba8ui", ast.ImageFormat.rgba8ui },
            .{ "r32ui", ast.ImageFormat.r32ui },
            .{ "rgb10_a2ui", ast.ImageFormat.rgb10_a2ui },
            .{ "rg32ui", ast.ImageFormat.rg32ui },
            .{ "rg16ui", ast.ImageFormat.rg16ui },
            .{ "rg8ui", ast.ImageFormat.rg8ui },
            .{ "r16ui", ast.ImageFormat.r16ui },
            .{ "r8ui", ast.ImageFormat.r8ui },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, text_in, entry[0])) return entry[1];
        }
        return null;
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
                } else if (std.mem.eql(u8, ident_text, "pixel_interlock_ordered")) {
                    layout.pixel_interlock_ordered = true;
                } else if (std.mem.eql(u8, ident_text, "pixel_interlock_unordered")) {
                    layout.pixel_interlock_unordered = true;
                } else if (std.mem.eql(u8, ident_text, "sample_interlock_ordered")) {
                    layout.sample_interlock_ordered = true;
                } else if (std.mem.eql(u8, ident_text, "sample_interlock_unordered")) {
                    layout.sample_interlock_unordered = true;
                } else if (std.mem.eql(u8, ident_text, "depth_greater")) {
                    layout.depth_greater = true;
                } else if (std.mem.eql(u8, ident_text, "depth_less")) {
                    layout.depth_less = true;
                } else if (std.mem.eql(u8, ident_text, "depth_unchanged")) {
                    layout.depth_unchanged = true;
                } else if (std.mem.eql(u8, ident_text, "triangles")) {
                    layout.output_topology = .triangles;
                    layout.input_topology = .triangles;
                } else if (std.mem.eql(u8, ident_text, "lines")) {
                    layout.output_topology = .lines;
                    layout.input_topology = .lines;
                } else if (std.mem.eql(u8, ident_text, "points")) {
                    layout.output_topology = .points;
                    layout.input_topology = .points;
                } else if (std.mem.eql(u8, ident_text, "triangles_adjacency")) {
                    layout.input_topology = .triangles_adjacency;
                } else if (std.mem.eql(u8, ident_text, "lines_adjacency")) {
                    layout.input_topology = .lines_adjacency;
                } else if (std.mem.eql(u8, ident_text, "triangle_strip")) {
                    layout.output_topology = .triangles;
                    layout.is_triangle_strip = true;
                } else if (std.mem.eql(u8, ident_text, "line_strip")) {
                    layout.output_topology = .lines;
                    layout.is_line_strip = true;
                } else if (std.mem.eql(u8, ident_text, "equal_spacing")) {
                    layout.equal_spacing = true;
                } else if (std.mem.eql(u8, ident_text, "fractional_even_spacing")) {
                    layout.fractional_even_spacing = true;
                } else if (std.mem.eql(u8, ident_text, "fractional_odd_spacing")) {
                    layout.fractional_odd_spacing = true;
                } else if (std.mem.eql(u8, ident_text, "ccw")) {
                    layout.vertex_order_ccw = true;
                } else if (std.mem.eql(u8, ident_text, "cw")) {
                    layout.vertex_order_cw = true;
                } else if (std.mem.eql(u8, ident_text, "isolines")) {
                    layout.isolines = true;
                } else if (std.mem.eql(u8, ident_text, "quads")) {
                    layout.quads = true;
                } else if (parseImageFormatIdent(ident_text)) |fmt| {
                    layout.image_format = fmt;
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
                    } else if (std.mem.eql(u8, ident_text, "max_vertices")) {
                        layout.max_vertices = std.fmt.parseInt(u32, val_text, 10) catch null;
                    } else if (std.mem.eql(u8, ident_text, "max_primitives")) {
                        layout.max_primitives = std.fmt.parseInt(u32, val_text, 10) catch null;
                    } else if (std.mem.eql(u8, ident_text, "vertices")) {
                        layout.vertices = std.fmt.parseInt(u32, val_text, 10) catch null;
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
            .kw_isampler_buffer => { _ = self.advance(); return .isampler_buffer; },
            .kw_usampler_buffer => { _ = self.advance(); return .usampler_buffer; },
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
            .kw_sampler_cube_array => { _ = self.advance(); return .sampler_cube_array; },
            .kw_sampler_cube_array_shadow => { _ = self.advance(); return .sampler_cube_array_shadow; },
            .kw_isampler_cube => { _ = self.advance(); return .isampler_cube; },
            .kw_usampler_cube => { _ = self.advance(); return .usampler_cube; },
            .kw_isampler_cube_array => { _ = self.advance(); return .isampler_cube_array; },
            .kw_usampler_cube_array => { _ = self.advance(); return .usampler_cube_array; },
            .kw_sampler2d_rect => { _ = self.advance(); return .sampler2d; },
            .kw_sampler1d_array => { _ = self.advance(); return .sampler1d_array; },
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
                // All identifiers (including 64-bit type names like `double`/`int64_t`,
                // which the lexer does not map to dedicated tokens) become `.named`.
                // 64-bit types are recognized in parseStatement via is64BitTypeName so the
                // semantic layer can emit a clear "unsupported 64-bit type" honest error.
                const name = self.text(self.current());
                _ = self.advance();
                return .{ .named = name };
            },
            else => null,
        };
    }

    // ── Declarations ──────────────────────────────────────────

    fn parseFunctionDecl(self: *Parser, name_tok: lexer.Token, ret_type: ast.Type, qualifier: ?ast.Qualifier, layout: ?ast.Layout) Error!ast.Node {
        _ = try self.expect(.l_paren);
        var params = std.ArrayListUnmanaged(ast.FunctionParam).empty;
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
            const p_type = self.tryType() orelse {
                self.recordErrorLoc();
                return error.UnexpectedToken;
            };
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
            if (p_name.tag != .identifier) {
                self.recordErrorLoc();
                return error.UnexpectedToken;
            }
            _ = self.advance();
            // Handle array dimensions after param name: e.g. float a[4] or float a[3][2]
            // Collect all bracket pairs (first is outermost dimension in GLSL notation).
            var final_type = p_type;
            var arr_dims: std.ArrayListUnmanaged(u32) = .empty;
            defer arr_dims.deinit(self.alloc);
            while (self.current().tag == .l_bracket) {
                _ = self.advance(); // consume [
                const size_tok = self.current();
                var arr_size: u32 = 0;
                if (size_tok.tag == .int_literal) {
                    arr_size = std.fmt.parseInt(u32, self.text(size_tok), 10) catch 0;
                    _ = self.advance();
                }
                _ = self.expect(.r_bracket) catch break;
                try arr_dims.append(self.alloc, arr_size);
            }
            // Build array type from outermost to innermost (reverse order, same as parseVarDecl)
            if (arr_dims.items.len > 0) {
                var i: usize = arr_dims.items.len;
                while (i > 0) {
                    i -= 1;
                    const arr_base = try self.createType(final_type);
                    final_type = .{ .array = .{ .base = arr_base, .size = arr_dims.items[i] } };
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
        var arr_dims: std.ArrayListUnmanaged(u32) = .empty;
        defer arr_dims.deinit(self.alloc);
        // For expression-based sizes (e.g. gl_WorkGroupSize.x), store the source text.
        // Only the first dimension's expression is tracked (covers the common case).
        var arr_size_expr: ?[]const u8 = null;
        while (self.current().tag == .l_bracket) {
            _ = self.advance();
            const size_tok = self.current();
            var arr_size: u32 = 0;
            if (size_tok.tag == .int_literal) {
                arr_size = std.fmt.parseInt(u32, self.text(size_tok), 0) catch 0;
                _ = self.advance();
                _ = self.expect(.r_bracket) catch break;
            } else if (size_tok.tag == .r_bracket) {
                // unsized array []
                _ = self.advance();
            } else {
                // Expression-based size: consume all tokens up to the matching ']'
                // and store the source text for semantic-time constant folding.
                const expr_start = size_tok.start;
                var expr_end: usize = expr_start;
                var depth: u32 = 0;
                while (self.current().tag != .eof) {
                    const cur = self.current();
                    if (cur.tag == .l_bracket) depth += 1;
                    if (cur.tag == .r_bracket) {
                        if (depth == 0) break;
                        depth -= 1;
                    }
                    expr_end = cur.start + cur.len;
                    _ = self.advance();
                }
                if (arr_size_expr == null) {
                    arr_size_expr = self.source[expr_start..expr_end];
                }
                _ = self.expect(.r_bracket) catch break;
                // arr_size stays 0; semantic.zig will fold the expression.
            }
            try arr_dims.append(self.alloc, arr_size);
        }
        // Build array type from outermost to innermost (reverse order)
        if (arr_dims.items.len > 0) {
            var i: usize = arr_dims.items.len;
            while (i > 0) {
                i -= 1;
                const arr_base = try self.createType(ty);
                // Attach size_name to the outermost dimension where it was set.
                const sname: ?[]const u8 = if (i == arr_dims.items.len - 1) arr_size_expr else null;
                ty = .{ .array = .{ .base = arr_base, .size = arr_dims.items[i], .size_name = sname } };
            }
        }
        var init_nodes = std.ArrayListUnmanaged(ast.Node).empty;
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
        if (name_tok.tag != .identifier) {
            self.recordErrorLoc();
            return error.UnexpectedToken;
        }
        _ = self.advance();
        // Register struct name for local var decl detection
        const owned_name = try self.alloc.dupe(u8, self.text(name_tok));
        const gop = try self.struct_names.getOrPut(self.alloc, owned_name);
        if (gop.found_existing) {
            // Key already exists, free the new duplicate
            self.alloc.free(owned_name);
        }

        _ = try self.expect(.l_brace);
        var members = std.ArrayListUnmanaged(ast.StructMember).empty;
        defer members.deinit(self.alloc);
        while (self.current().tag != .r_brace and self.current().tag != .eof) {
            var member_layout: ?ast.Layout = null;
            if (self.current().tag == .kw_layout) member_layout = try self.tryLayout();
            const member_qual = self.tryQualifier();
            const member_ty = self.tryType() orelse {
                self.recordErrorLoc();
                return error.UnexpectedToken;
            };
            const member_name = self.current();
            if (member_name.tag != .identifier) {
                self.recordErrorLoc();
                return error.UnexpectedToken;
            }
            _ = self.advance();
            // Check for array size suffix: vec2 a[1] (supports multi-dim: vec2 a[2][3])
            var member_ty_final = member_ty;
            var member_arr_dims: std.ArrayListUnmanaged(u32) = .empty;
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
        var members = std.ArrayListUnmanaged(ast.StructMember).empty;
        defer members.deinit(self.alloc);
        while (self.current().tag != .r_brace and self.current().tag != .eof) {
            var member_layout: ?ast.Layout = null;
            if (self.current().tag == .kw_layout) member_layout = try self.tryLayout();
            const member_qual = self.tryQualifier();
            const member_ty = self.tryType() orelse {
                self.recordErrorLoc();
                return error.UnexpectedToken;
            };
            const member_name = self.current();
            if (member_name.tag != .identifier) {
                self.recordErrorLoc();
                return error.UnexpectedToken;
            }
            _ = self.advance();
            // Check for array size suffix: vec2 a[1] (supports multi-dim: vec2 a[2][3])
            var member_ty_final = member_ty;
            var member_arr_dims: std.ArrayListUnmanaged(u32) = .empty;
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
        // Consume optional instance name: } instance_name[N];
        // `int_val` on the node is repurposed to carry the instance array size (0 = not an array).
        var instance_name: []const u8 = "";
        var instance_array_size: i64 = 0;
        if (self.current().tag == .identifier) {
            instance_name = self.text(self.current());
            _ = self.advance(); // consume instance name
            // Optionally consume array dimension: instance_name[N]
            if (self.current().tag == .l_bracket) {
                _ = self.advance(); // consume [
                const size_tok = self.current();
                if (size_tok.tag == .int_literal) {
                    instance_array_size = std.fmt.parseInt(i64, self.text(size_tok), 0) catch 0;
                    _ = self.advance();
                }
                _ = self.expect(.r_bracket) catch {};
            }
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
                .int_val = instance_array_size,
            },
        };
    }

    // ── Statements ────────────────────────────────────────────

    fn parseBlock(self: *Parser) Error![]const ast.Node {
        _ = try self.expect(.l_brace);
        var stmts = std.ArrayListUnmanaged(ast.Node).empty;
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
            // Recognize 64-bit type keywords (not in the lexer keyword map) so that
            // `double d = ...` / `int64_t n = ...` are parsed as var-decls and the
            // semantic layer can emit a clear "unsupported 64-bit type" honest error.
            if (is64BitTypeName(type_name) and
                (self.peek2().tag == .eq or self.peek2().tag == .semicolon or
                 self.peek2().tag == .l_bracket or self.peek2().tag == .semicolon))
            {
                return self.parseLocalVarDecl();
            }
        }
        // const type identifier ...
        if (cur == .kw_const and (isTypeKeyword(nxt) or nxt == .identifier)) {
            return self.parseLocalVarDecl();
        }
        // precision qualifier type identifier: mediump int x = 0; highp float y;
        // parseLocalVarDecl already handles precision qualifiers via tryQualifier(),
        // but parseStatement didn't recognize them as var-decl starters.
        if ((cur == .kw_mediump or cur == .kw_highp or cur == .kw_lowp) and isTypeKeyword(nxt)) {
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
            self.recordErrorLoc();
            return error.UnexpectedToken;
        };
        const name_tok = self.current();
        if (name_tok.tag != .identifier) {
            self.recordErrorLoc();
            return error.UnexpectedToken;
        }
        _ = self.advance();

        // Nested function definition: `type identifier ( … ) {` at statement
        // scope. GLSL forbids defining a function inside a function body, and
        // glslang rejects it with "unexpected LEFT_BRACE, expecting SEMICOLON".
        // Mark it fatal so the compile fails loudly instead of silently dropping
        // the body and emitting a hollow module.
        //
        // We must NOT fire on a *prototype* (`type identifier ( … ) ;`): a local
        // function declaration is legal GLSL (glslang accepts `int g();` inside
        // a body). `nestedFunctionBodyFollows` distinguishes them by looking for
        // the `{` body; a prototype (or any other shape) falls through to the
        // existing handling, which recovers exactly as before.
        if (self.current().tag == .l_paren and self.nestedFunctionBodyFollows()) {
            self.recordErrorLoc();
            semantic.last_error_ctx = "nested function definition";
            semantic.last_error_inner = "nested function definitions are not allowed in GLSL";
            self.fatal_parse_error = true;
            return error.UnexpectedToken;
        }

        // Handle array size suffix: float a[4], int a[b] (b a spec const), a[gl_WorkGroupSize.x]
        var local_arr_dims: std.ArrayListUnmanaged(u32) = .empty;
        defer local_arr_dims.deinit(self.alloc);
        var local_arr_size_expr: ?[]const u8 = null;
        while (self.current().tag == .l_bracket) {
            _ = self.advance();
            const size_tok = self.current();
            var arr_size: u32 = 0;
            if (size_tok.tag == .int_literal) {
                arr_size = std.fmt.parseInt(u32, self.text(size_tok), 0) catch 0;
                _ = self.advance();
                _ = self.expect(.r_bracket) catch break;
            } else if (size_tok.tag == .r_bracket) {
                // unsized array []
                _ = self.advance();
            } else {
                // Expression-based size (spec constant, gl_WorkGroupSize.x, const int, …):
                // consume tokens up to the matching ']' and capture the source text so
                // semantic.zig can fold it (mirrors parseVarDecl). arr_size stays 0.
                const expr_start = size_tok.start;
                var expr_end: usize = expr_start;
                var depth: u32 = 0;
                while (self.current().tag != .eof) {
                    const cur = self.current();
                    if (cur.tag == .l_bracket) depth += 1;
                    if (cur.tag == .r_bracket) {
                        if (depth == 0) break;
                        depth -= 1;
                    }
                    expr_end = cur.start + cur.len;
                    _ = self.advance();
                }
                if (local_arr_size_expr == null) {
                    local_arr_size_expr = self.source[expr_start..expr_end];
                }
                _ = self.expect(.r_bracket) catch break;
            }
            try local_arr_dims.append(self.alloc, arr_size);
        }
        if (local_arr_dims.items.len > 0) {
            var i: usize = local_arr_dims.items.len;
            while (i > 0) {
                i -= 1;
                const arr_base = try self.createType(ty);
                // Attach size_name to the outermost dimension where it was set.
                const sname: ?[]const u8 = if (i == local_arr_dims.items.len - 1) local_arr_size_expr else null;
                ty = .{ .array = .{ .base = arr_base, .size = local_arr_dims.items[i], .size_name = sname } };
            }
        }

        var init_nodes = std.ArrayListUnmanaged(ast.Node).empty;
        defer init_nodes.deinit(self.alloc);
        if (self.current().tag == .eq) {
            _ = self.advance();
            try init_nodes.append(self.alloc, try self.parseExpression());
        }

        // Handle comma-separated declarations: int i = 1, j = 4;
        var decl_children = std.ArrayListUnmanaged(ast.Node).empty;
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
            var next_init = std.ArrayListUnmanaged(ast.Node).empty;
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

        var children = std.ArrayListUnmanaged(ast.Node).empty;
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

        var children = std.ArrayListUnmanaged(ast.Node).empty;
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
        var children = std.ArrayListUnmanaged(ast.Node).empty;
        defer children.deinit(self.alloc);
        // Store selector expression in the first child slot
        const expr_node = expr; // Capture before dupeNodes
        while (self.current().tag != .r_brace and self.current().tag != .eof) {
            if (self.current().tag == .kw_case) {
                _ = self.advance();
                const val = try self.parseExpression();
                _ = try self.expect(.colon);
                // Parse statements until next case/default/}
                var case_body = std.ArrayListUnmanaged(ast.Node).empty;
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
                var case_body = std.ArrayListUnmanaged(ast.Node).empty;
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
        var all_children = std.ArrayListUnmanaged(ast.Node).empty;
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
        var children = std.ArrayListUnmanaged(ast.Node).empty;
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
                .l_paren => {
                    // Method call: expr.method(args) — transform member_access into func_call
                    if (expr.tag == .member_access) {
                        _ = self.advance(); // consume '('
                        var args = std.ArrayListUnmanaged(ast.Node).empty;
                        defer args.deinit(self.alloc);
                        // First arg is the base expression
                        if (expr.data.children.len > 0)
                            try args.append(self.alloc, expr.data.children[0]);
                        while (self.current().tag != .r_paren and self.current().tag != .eof) {
                            try args.append(self.alloc, try self.parseExpression());
                            if (self.current().tag == .comma) _ = self.advance();
                        }
                        _ = self.expect(.r_paren) catch {};
                        expr = .{
                            .tag = .func_call,
                            .loc = expr.loc,
                            .data = .{ .name = expr.data.name, .children = try self.ownedChildren(&args) },
                        };
                    } else {
                        // Not a method call — function-style call on expression
                        // This shouldn't normally happen in valid GLSL
                        break;
                    }
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
                // num_text is the literal's NON-NEGATIVE magnitude (a leading `-`
                // is a separate unary_op) with the u/U suffix stripped. Parse it as
                // u64 to cover the full range a literal can spell — including the
                // 2^63..2^64-1 band that overflows i64 (e.g. 18446744073709551615u).
                // @bitCast to i64 for storage in int_val is a lossless reinterpret;
                // the semantic layer's literalWord @bitCasts back to u64 and rejects
                // magnitudes > 0xFFFFFFFF, since glslpp has no 64-bit integer type.
                // Parsing as i64 with `catch 0` instead would silently turn such a
                // literal into the constant 0 before literalWord ever saw the real
                // value — a silent-wrong constant. A literal that overflows even u64
                // (or is otherwise malformed) falls back to the sentinel i64 -1,
                // whose u64 reinterpret (0xFFFFFFFFFFFFFFFF) literalWord likewise
                // rejects, so it errors honestly via the same channel rather than
                // becoming a silent 0.
                const val: i64 = @bitCast(std.fmt.parseInt(u64, num_text, 0) catch @as(u64, std.math.maxInt(u64)));
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
                // A malformed float literal — the lexer accepts an exponent marker with no
                // exponent digits (`1e`, `1.5e+`), which std.fmt.parseFloat rejects. glslang
                // rejects these too ("bad character in float exponent"); fail loud rather than
                // silently substituting 0.0 (silent-wrong), mirroring the int path above which
                // routes a malformed/over-range literal to an honest downstream rejection.
                const val = std.fmt.parseFloat(f64, num_text) catch {
                    self.recordErrorLoc();
                    return error.UnexpectedToken;
                };
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
                        var args = std.ArrayListUnmanaged(ast.Node).empty;
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
                    var args = std.ArrayListUnmanaged(ast.Node).empty;
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
            // Vulkan SHADOW combined-sampler constructors built from a separate
            // texture + samplerShadow (e.g. `sampler2DShadow(tex, samp)`). These
            // were omitted, so a `texture(sampler2DShadow(t, s), …)` expression was
            // not parsed as a constructor and the whole statement was silently
            // DROPPED — the depth compare vanished (frontend silent-wrong).
            // ONLY the variants with an EXACT ast.Type are listed: sampler1D-
            // ArrayShadow and sampler2DRectShadow fold to a DIFFERENT dimension in
            // tryType (no dedicated ast.Type variant), so enabling them as
            // constructors would trade the drop for a wrong-dimension silent-wrong.
            // They remain unsupported (rare/legacy types) rather than mis-lowered.
            .kw_sampler2d_shadow, .kw_sampler1d_shadow,
            .kw_sampler2d_array_shadow,
            .kw_sampler_cube_shadow, .kw_sampler_cube_array_shadow,
            => {
                var ty = self.tryType().?;
                // Handle array constructors: float[](1.0, 2.0, ...), vec4[](...),
                // float[2][3](...), vec4[][](...). Collect ALL bracket dims in
                // source order first (0 marks an unsized `[]` dim), then wrap
                // outermost-to-innermost so `float[2][3]` becomes
                // array{size=2, base=array{size=3, base=float}} — matching the
                // SPIR-V layout `OpTypeArray %inner %outerLen` and the correct
                // declaration-side logic in parseDeclaration (see ~line 1052).
                var ctor_dims = std.ArrayListUnmanaged(u32).empty;
                defer ctor_dims.deinit(self.alloc);
                while (self.current().tag == .l_bracket) {
                    _ = self.advance(); // [
                    if (self.current().tag == .r_bracket) {
                        _ = self.advance(); // ]
                        // Unsized array dim: base_type[]
                        try ctor_dims.append(self.alloc, 0);
                    } else {
                        // Sized array dim: base_type[N]
                        const size_tok = self.current();
                        _ = self.advance(); // size
                        _ = self.expect(.r_bracket) catch {};
                        const size_val = std.fmt.parseInt(u32, self.text(size_tok), 0) catch 0;
                        try ctor_dims.append(self.alloc, size_val);
                    }
                }
                // Reverse-wrap: innermost dim first, outermost dim last.
                if (ctor_dims.items.len > 0) {
                    var di: usize = ctor_dims.items.len;
                    while (di > 0) {
                        di -= 1;
                        const arr_base = try self.createType(ty);
                        ty = .{ .array = .{ .base = arr_base, .size = ctor_dims.items[di] } };
                    }
                }
                _ = self.expect(.l_paren) catch return .{
                    .tag = .type_constructor,
                    .loc = self.nodeLoc(tok),
                    .data = .{ .ty = ty },
                };
                var args = std.ArrayListUnmanaged(ast.Node).empty;
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
                    var args = std.ArrayListUnmanaged(ast.Node).empty;
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

test "nested function definition fails loud (not silently dropped)" {
    // GLSL forbids defining a function inside a function body. The parser
    // recovers from the malformed statement so it can keep scanning, but the
    // overall parse must surface an error rather than returning a hollow tree.
    const alloc = std.testing.allocator;
    const source =
        \\void main() {
        \\    float f(float x) { return x; }
        \\}
    ;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    semantic.last_error_line = 0;
    try std.testing.expectError(error.UnexpectedToken, parse(alloc, source, tokens));
    // The diagnostic must pin the nested-function line (line 2), proving the
    // error came from the nested-function path and that continued recovery did
    // not overwrite the location with the closing-brace line (3).
    try std.testing.expectEqual(@as(u32, 2), semantic.last_error_line);
}

test "local function prototype does not fail loud (valid GLSL)" {
    // A local prototype `type identifier ( … ) ;` is legal GLSL (glslang
    // accepts `float g(float x);` inside a body). It must NOT trip the
    // nested-function fail-loud — only a `{` body is a (forbidden) definition.
    // (glslpp doesn't yet parse local prototypes faithfully; it recovers and
    // drops the statement. The point here is only that it does NOT fail loud.)
    const alloc = std.testing.allocator;
    const source = "void main() { float g(float x); }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens); // must NOT return an error
    defer freeTree(alloc, &root);
    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    try std.testing.expectEqual(ast.Node.Tag.function_decl, root.body[0].tag);
}

test "ordinary function-call statement still parses (call vs nested-def)" {
    // Guard against the nested-function detection misfiring: a call is
    // `identifier (`, not `type identifier (`, so it must parse fine AND the
    // call statement must survive in the body (not be silently dropped).
    const alloc = std.testing.allocator;
    const source = "void main() { foo(1.0); }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parse(alloc, source, tokens);
    defer freeTree(alloc, &root);
    try std.testing.expectEqual(@as(usize, 1), root.body.len);
    const func = root.body[0];
    try std.testing.expectEqual(ast.Node.Tag.function_decl, func.tag);
    try std.testing.expectEqual(@as(usize, 1), func.data.children.len);
    try std.testing.expectEqual(ast.Node.Tag.expr_stmt, func.data.children[0].tag);
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

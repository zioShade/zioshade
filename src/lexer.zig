const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    start: u32,
    len: u32,

    pub const Loc = struct {
        line: u32,
        column: u32,
    };

    pub const Tag = enum {
        // Literals
        int_literal,
        uint_literal,
        float_literal,
        double_literal,
        string_literal,

        // Identifier
        identifier,

        // Keywords
        kw_version,
        kw_void,
        kw_float,
        kw_int,
        kw_uint,
        kw_bool,
        kw_vec2,
        kw_vec3,
        kw_vec4,
        kw_ivec2,
        kw_ivec3,
        kw_ivec4,
        kw_bvec2,
        kw_bvec3,
        kw_bvec4,
        kw_uvec2,
        kw_uvec3,
        kw_uvec4,
        kw_mat2,
        kw_mat3,
        kw_mat4,
        kw_mat2x2,
        kw_mat2x3,
        kw_mat2x4,
        kw_mat3x2,
        kw_mat3x3,
        kw_mat3x4,
        kw_mat4x2,
        kw_mat4x3,
        kw_mat4x4,
        kw_sampler2d,
        kw_isampler2d,
        kw_usampler2d,
        kw_sampler2d_array,
        kw_sampler3d,
        kw_sampler_buffer,
        kw_sampler2d_ms,
        kw_sampler_cube_array,
        kw_isampler_cube,
        kw_usampler_cube,
        kw_isampler3d,
        kw_usampler3d,
        kw_sampler2d_shadow,
        kw_sampler1d,
        kw_isampler1d,
        kw_usampler1d,
        kw_sampler1d_shadow,
        kw_sampler_cube_shadow,
        kw_sampler2d_array_shadow,
        kw_sampler1d_array_shadow,
        kw_sampler2d_ms_array,
        kw_isampler2d_array,
        kw_usampler2d_array,
        kw_isampler2d_ms,
        kw_usampler2d_ms,
        kw_isampler2d_ms_array,
        kw_usampler2d_ms_array,
        kw_isampler_cube_array,
        kw_usampler_cube_array,
        kw_sampler2d_rect,
        kw_sampler2d_rect_shadow,
        kw_sampler1d_array,
        kw_isampler1d_array,
        kw_usampler1d_array,
        kw_image2d,
        kw_iimage2d,
        kw_uimage2d,
        kw_image3d,
        kw_imagecube,
        kw_image2d_array,
        kw_image_buffer,
        kw_image2d_ms,
        kw_image2d_ms_array,
        kw_texture2d,
        kw_sampler_shadow,
        kw_sampler_plain,
        kw_sampler_cube,
        kw_struct,
        kw_switch,
        kw_case,
        kw_default,
        kw_precision,
        kw_mediump,
        kw_highp,
        kw_lowp,
        kw_in,
        kw_out,
        kw_inout,
        kw_uniform,
        kw_const,
        kw_buffer,
        kw_readonly,
        kw_writeonly,
        kw_coherent,
        kw_restrict,
        kw_invariant,
        kw_flat,
        kw_smooth,
        kw_noperspective,
        kw_layout,
        kw_if,
        kw_else,
        kw_for,
        kw_while,
        kw_do,
        kw_return,
        kw_discard,
        kw_break,
        kw_continue,
        kw_true,
        kw_false,

        // Preprocessor directives
        pp_version,
        pp_define,
        pp_undef,
        pp_if,
        pp_ifdef,
        pp_ifndef,
        pp_elif,
        pp_else,
        pp_endif,
        pp_error,
        pp_pragma,
        pp_line,
        pp_extension,
        pp_include,

        // Operators
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,
        comma,
        semicolon,
        colon,
        question,
        dot,
        tilde,
        bang,
        at,
        hash,
        hash_hash,
        plus,
        minus,
        star,
        slash,
        percent,
        ampersand,
        pipe,
        caret,
        lt,
        gt,
        lshift,
        rshift,
        eq,
        eq_eq,
        bang_eq,
        lt_eq,
        gt_eq,
        ampersand_ampersand,
        pipe_pipe,
        caret_caret,
        plus_eq,
        minus_eq,
        star_eq,
        slash_eq,
        percent_eq,
        ampersand_eq,
        pipe_eq,
        caret_eq,
        lshift_eq,
        rshift_eq,
        plus_plus,
        minus_minus,

        // Special
        eof,
        invalid,
    };
};

pub const Error = error{
    OutOfMemory,
    InvalidToken,
    UnterminatedComment,
};

const KeywordMap = std.StaticStringMap(Token.Tag);
const PPDirectiveMap = std.StaticStringMap(Token.Tag);

fn makeKeywordMap() KeywordMap {
    return comptime KeywordMap.initComptime(.{
        .{ "version", .kw_version },
        .{ "void", .kw_void },
        .{ "float", .kw_float },
        .{ "int", .kw_int },
        .{ "uint", .kw_uint },
        .{ "bool", .kw_bool },
        .{ "vec2", .kw_vec2 },
        .{ "vec3", .kw_vec3 },
        .{ "vec4", .kw_vec4 },
        .{ "ivec2", .kw_ivec2 },
        .{ "ivec3", .kw_ivec3 },
        .{ "ivec4", .kw_ivec4 },
        .{ "bvec2", .kw_bvec2 },
        .{ "bvec3", .kw_bvec3 },
        .{ "bvec4", .kw_bvec4 },
        .{ "uvec2", .kw_uvec2 },
        .{ "uvec3", .kw_uvec3 },
        .{ "uvec4", .kw_uvec4 },
        .{ "mat2", .kw_mat2 },
        .{ "mat3", .kw_mat3 },
        .{ "mat4", .kw_mat4 },
        .{ "mat2x2", .kw_mat2x2 },
        .{ "mat2x3", .kw_mat2x3 },
        .{ "mat2x4", .kw_mat2x4 },
        .{ "mat3x2", .kw_mat3x2 },
        .{ "mat3x3", .kw_mat3x3 },
        .{ "mat3x4", .kw_mat3x4 },
        .{ "mat4x2", .kw_mat4x2 },
        .{ "mat4x3", .kw_mat4x3 },
        .{ "mat4x4", .kw_mat4x4 },
        .{ "sampler2D", .kw_sampler2d },
        .{ "isampler2D", .kw_isampler2d },
        .{ "usampler2D", .kw_usampler2d },
        .{ "sampler2DArray", .kw_sampler2d_array },
        .{ "sampler3D", .kw_sampler3d },
        .{ "samplerBuffer", .kw_sampler_buffer },
        .{ "sampler2DMS", .kw_sampler2d_ms },
        .{ "samplerCubeArray", .kw_sampler_cube_array },
        .{ "isamplerCube", .kw_isampler_cube },
        .{ "usamplerCube", .kw_usampler_cube },
        .{ "isampler3D", .kw_isampler3d },
        .{ "usampler3D", .kw_usampler3d },
        .{ "sampler2DShadow", .kw_sampler2d_shadow },
        .{ "sampler1D", .kw_sampler1d },
        .{ "isampler1D", .kw_isampler1d },
        .{ "usampler1D", .kw_usampler1d },
        .{ "sampler1DShadow", .kw_sampler1d_shadow },
        .{ "samplerCubeShadow", .kw_sampler_cube_shadow },
        .{ "sampler2DArrayShadow", .kw_sampler2d_array_shadow },
        .{ "sampler1DArrayShadow", .kw_sampler1d_array_shadow },
        .{ "sampler2DMSArray", .kw_sampler2d_ms_array },
        .{ "isampler2DArray", .kw_isampler2d_array },
        .{ "usampler2DArray", .kw_usampler2d_array },
        .{ "isampler2DMS", .kw_isampler2d_ms },
        .{ "usampler2DMS", .kw_usampler2d_ms },
        .{ "isampler2DMSArray", .kw_isampler2d_ms_array },
        .{ "usampler2DMSArray", .kw_usampler2d_ms_array },
        .{ "isamplerCubeArray", .kw_isampler_cube_array },
        .{ "usamplerCubeArray", .kw_usampler_cube_array },
        .{ "sampler2DRect", .kw_sampler2d_rect },
        .{ "sampler2DRectShadow", .kw_sampler2d_rect_shadow },
        .{ "sampler1DArray", .kw_sampler1d_array },
        .{ "isampler1DArray", .kw_isampler1d_array },
        .{ "usampler1DArray", .kw_usampler1d_array },
        .{ "image2D", .kw_image2d },
        .{ "iimage2D", .kw_iimage2d },
        .{ "uimage2D", .kw_uimage2d },
        .{ "image3D", .kw_image3d },
        .{ "imageCube", .kw_imagecube },
        .{ "image2DArray", .kw_image2d_array },
        .{ "imageBuffer", .kw_image_buffer },
        .{ "image2DMS", .kw_image2d_ms },
        .{ "image2DMSArray", .kw_image2d_ms_array },
        .{ "texture2D", .kw_texture2d },
        .{ "samplerShadow", .kw_sampler_shadow },
        .{ "sampler", .kw_sampler_plain },
        .{ "samplerCube", .kw_sampler_cube },
        .{ "struct", .kw_struct },
        .{ "switch", .kw_switch },
        .{ "case", .kw_case },
        .{ "default", .kw_default },
        .{ "precision", .kw_precision },
        .{ "mediump", .kw_mediump },
        .{ "highp", .kw_highp },
        .{ "lowp", .kw_lowp },
        .{ "in", .kw_in },
        .{ "out", .kw_out },
        .{ "inout", .kw_inout },
        .{ "uniform", .kw_uniform },
        .{ "const", .kw_const },
        .{ "buffer", .kw_buffer },
        .{ "readonly", .kw_readonly },
        .{ "writeonly", .kw_writeonly },
        .{ "coherent", .kw_coherent },
        .{ "restrict", .kw_restrict },
        .{ "invariant", .kw_invariant },
        .{ "flat", .kw_flat },
        .{ "smooth", .kw_smooth },
        .{ "noperspective", .kw_noperspective },
        .{ "layout", .kw_layout },
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "for", .kw_for },
        .{ "while", .kw_while },
        .{ "do", .kw_do },
        .{ "return", .kw_return },
        .{ "discard", .kw_discard },
        .{ "break", .kw_break },
        .{ "continue", .kw_continue },
        .{ "true", .kw_true },
        .{ "false", .kw_false },
    });
}

fn makePPDirectiveMap() PPDirectiveMap {
    return comptime PPDirectiveMap.initComptime(.{
        .{ "version", .pp_version },
        .{ "define", .pp_define },
        .{ "undef", .pp_undef },
        .{ "if", .pp_if },
        .{ "ifdef", .pp_ifdef },
        .{ "ifndef", .pp_ifndef },
        .{ "elif", .pp_elif },
        .{ "else", .pp_else },
        .{ "endif", .pp_endif },
        .{ "error", .pp_error },
        .{ "pragma", .pp_pragma },
        .{ "line", .pp_line },
        .{ "extension", .pp_extension },
        .{ "include", .pp_include },
    });
}

const keyword_map = makeKeywordMap();
const pp_directive_map = makePPDirectiveMap();

pub fn tokenize(alloc: std.mem.Allocator, source: [:0]const u8) Error![]const Token {
    var tokenizer = Tokenizer{
        .source = source,
        .tokens = .{},
        .loc = .{ .line = 1, .column = 1 },
    };
    try tokenizer.run(alloc);
    return tokenizer.tokens.toOwnedSlice(alloc);
}

const Tokenizer = struct {
    source: [:0]const u8,
    tokens: std.ArrayListUnmanaged(Token),
    loc: Token.Loc,
    offset: u32 = 0,

    fn run(self: *Tokenizer, alloc: std.mem.Allocator) Error!void {
        while (true) {
            self.skipWhitespace();

            if (self.offset >= self.source.len) {
                try self.tokens.append(alloc, .{
                    .tag = .eof,
                    .loc = self.loc,
                    .start = self.offset,
                    .len = 0,
                });
                break;
            }

            const start = self.offset;
            const start_loc = self.loc;

            // Check for preprocessor directive at start of line
            if (self.source[self.offset] == '#') {
                const tag = try self.parsePPDirective();
                const len = self.offset - start;
                try self.tokens.append(alloc, .{
                    .tag = tag,
                    .loc = start_loc,
                    .start = start,
                    .len = @intCast(len),
                });
                continue;
            }

            // Check for comments
            if (self.offset + 1 < self.source.len) {
                if (self.source[self.offset] == '/' and self.source[self.offset + 1] == '/') {
                    _ = self.parseLineComment();
                    continue;
                }
                if (self.source[self.offset] == '/' and self.source[self.offset + 1] == '*') {
                    try self.parseBlockComment(alloc);
                    continue;
                }
            }

            // Check for string literals
            if (self.source[self.offset] == '"') {
                const str_len = try self.parseStringLiteral();
                try self.tokens.append(alloc, .{
                    .tag = .string_literal,
                    .loc = start_loc,
                    .start = start,
                    .len = @intCast(str_len),
                });
                continue;
            }

            // Check for identifiers and keywords
            if (isIdentifierStart(self.source[self.offset])) {
                const ident_len = self.parseIdentifier();
                const ident = self.source[start..start + ident_len];
                const tag = keyword_map.get(ident) orelse .identifier;
                try self.tokens.append(alloc, .{
                    .tag = tag,
                    .loc = start_loc,
                    .start = start,
                    .len = @intCast(ident_len),
                });
                continue;
            }

            // Check for numeric literals
            if (isDigit(self.source[self.offset]) or (self.source[self.offset] == '.')) {
                if (self.tryParseNumber()) |num_len| {
                    const num_str = self.source[start..start + num_len];
                    const tag = classifyNumber(num_str);
                    try self.tokens.append(alloc, .{
                        .tag = tag,
                        .loc = start_loc,
                        .start = start,
                        .len = @intCast(num_len),
                    });
                    continue;
                }
            }

            // Check for operators
            if (self.tryParseOperator()) |op_info| {
                try self.tokens.append(alloc, .{
                    .tag = op_info.tag,
                    .loc = start_loc,
                    .start = start,
                    .len = op_info.len,
                });
                continue;
            }

            // Invalid token
            return error.InvalidToken;
        }
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.offset < self.source.len) {
            const c = self.source[self.offset];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.offset += 1;
                self.loc.column += 1;
            } else if (c == '\n') {
                self.offset += 1;
                self.loc.line += 1;
                self.loc.column = 1;
            } else {
                break;
            }
        }
    }

    fn parsePPDirective(self: *Tokenizer) Error!Token.Tag {
        std.debug.assert(self.source[self.offset] == '#');
        self.offset += 1;
        self.loc.column += 1;

        // Skip whitespace after #
        while (self.offset < self.source.len and (self.source[self.offset] == ' ' or self.source[self.offset] == '\t')) {
            self.offset += 1;
            self.loc.column += 1;
        }

        // Parse the directive name
        const start = self.offset;
        while (self.offset < self.source.len and isIdentifierStart(self.source[self.offset])) {
            self.offset += 1;
            self.loc.column += 1;
        }

        if (start == self.offset) {
            return error.InvalidToken;
        }

        const directive = self.source[start..self.offset];
        const tag = pp_directive_map.get(directive) orelse return error.InvalidToken;

        return tag;
    }

    fn parseLineComment(self: *Tokenizer) void {
        std.debug.assert(self.source[self.offset] == '/' and self.source[self.offset + 1] == '/');
        self.offset += 2;
        self.loc.column += 2;

        while (self.offset < self.source.len) {
            if (self.source[self.offset] == '\n') {
                break;
            }
            self.offset += 1;
            self.loc.column += 1;
        }
    }

    fn parseBlockComment(self: *Tokenizer, alloc: std.mem.Allocator) Error!void {
        _ = alloc;
        std.debug.assert(self.source[self.offset] == '/' and self.source[self.offset + 1] == '*');
        self.offset += 2;
        self.loc.column += 2;

        // Block comments do NOT nest in GLSL — /* inside a comment is just text
        while (self.offset + 1 < self.source.len) {
            if (self.source[self.offset] == '*' and self.source[self.offset + 1] == '/') {
                self.offset += 2;
                self.loc.column += 2;
                return;
            } else if (self.source[self.offset] == '\n') {
                self.offset += 1;
                self.loc.line += 1;
                self.loc.column = 1;
            } else {
                self.offset += 1;
                self.loc.column += 1;
            }
        }
        // Unterminated comment — just return, no error
    }

    fn parseStringLiteral(self: *Tokenizer) Error!u32 {
        std.debug.assert(self.source[self.offset] == '"');
        const start = self.offset;
        self.offset += 1;
        self.loc.column += 1;

        while (self.offset < self.source.len) {
            const c = self.source[self.offset];
            if (c == '"') {
                self.offset += 1;
                self.loc.column += 1;
                return self.offset - start;
            }
            if (c == '\n') {
                return error.InvalidToken;
            }
            if (c == '\\' and self.offset + 1 < self.source.len) {
                self.offset += 2;
                self.loc.column += 2;
            } else {
                self.offset += 1;
                self.loc.column += 1;
            }
        }

        return error.InvalidToken;
    }

    fn parseIdentifier(self: *Tokenizer) u32 {
        const start = self.offset;
        while (self.offset < self.source.len) {
            const c = self.source[self.offset];
            if (isIdentifierStart(c) or isDigit(c)) {
                self.offset += 1;
                self.loc.column += 1;
            } else {
                break;
            }
        }
        return self.offset - start;
    }

    fn tryParseNumber(self: *Tokenizer) ?u32 {
        const start = self.offset;

        // Handle hex literals
        if (self.offset + 1 < self.source.len and self.source[self.offset] == '0' and (self.source[self.offset + 1] == 'x' or self.source[self.offset + 1] == 'X')) {
            self.offset += 2;
            while (self.offset < self.source.len and isHexDigit(self.source[self.offset])) {
                self.offset += 1;
            }
            // Check for suffix
            if (self.offset < self.source.len and (self.source[self.offset] == 'u' or self.source[self.offset] == 'U')) {
                self.offset += 1;
            }
            return self.offset - start;
        }

        // Handle decimal numbers
        var has_digit = false;
        var has_dot = false;
        var has_exponent = false;

        while (self.offset < self.source.len) {
            const c = self.source[self.offset];
            if (isDigit(c)) {
                self.offset += 1;
                has_digit = true;
            } else if (c == '.' and !has_dot) {
                self.offset += 1;
                has_dot = true;
            } else if ((c == 'e' or c == 'E') and !has_exponent and has_digit) {
                self.offset += 1;
                has_exponent = true;
                if (self.offset < self.source.len and (self.source[self.offset] == '+' or self.source[self.offset] == '-')) {
                    self.offset += 1;
                }
            } else {
                break;
            }
        }

        // Check for float suffix
        if (self.offset < self.source.len and (self.source[self.offset] == 'f' or self.source[self.offset] == 'F')) {
            self.offset += 1;
        }

        // Check for uint suffix
        if (!has_dot and !has_exponent and self.offset < self.source.len and (self.source[self.offset] == 'u' or self.source[self.offset] == 'U')) {
            self.offset += 1;
        }

        if (has_digit or has_dot) {
            return self.offset - start;
        }

        self.offset = start;
        return null;
    }

    const OperatorInfo = struct { tag: Token.Tag, len: u32 };

    fn tryParseOperator(self: *Tokenizer) ?OperatorInfo {
        const s = self.source;
        const i = self.offset;

        // Check for three-character operators first (<<= and >>=)
        if (i + 2 < s.len) {
            if (s[i] == '<' and s[i+1] == '<' and s[i+2] == '=') {
                self.offset += 3;
                self.loc.column += 3;
                return .{ .tag = .lshift_eq, .len = 3 };
            }
            if (s[i] == '>' and s[i+1] == '>' and s[i+2] == '=') {
                self.offset += 3;
                self.loc.column += 3;
                return .{ .tag = .rshift_eq, .len = 3 };
            }
        }

        // Two-character operators
        if (i + 1 < s.len) {
            const c0 = s[i];
            const c1 = s[i+1];
            const tag: ?Token.Tag = if (c0 == '<' and c1 == '<') .lshift
                else if (c0 == '>' and c1 == '>') .rshift
                else if (c0 == '=' and c1 == '=') .eq_eq
                else if (c0 == '!' and c1 == '=') .bang_eq
                else if (c0 == '<' and c1 == '=') .lt_eq
                else if (c0 == '>' and c1 == '=') .gt_eq
                else if (c0 == '&' and c1 == '&') .ampersand_ampersand
                else if (c0 == '|' and c1 == '|') .pipe_pipe
                else if (c0 == '^' and c1 == '^') .caret_caret
                else if (c0 == '+' and c1 == '=') .plus_eq
                else if (c0 == '-' and c1 == '=') .minus_eq
                else if (c0 == '*' and c1 == '=') .star_eq
                else if (c0 == '/' and c1 == '=') .slash_eq
                else if (c0 == '%' and c1 == '=') .percent_eq
                else if (c0 == '&' and c1 == '=') .ampersand_eq
                else if (c0 == '|' and c1 == '=') .pipe_eq
                else if (c0 == '^' and c1 == '=') .caret_eq
                else if (c0 == '+' and c1 == '+') .plus_plus
                else if (c0 == '-' and c1 == '-') .minus_minus
                else if (c0 == '#' and c1 == '#') .hash_hash
                else null;

            if (tag) |t| {
                self.offset += 2;
                self.loc.column += 2;
                return .{ .tag = t, .len = 2 };
            }
        }

        // Single-character operators
        if (i < s.len) {
            const tag: ?Token.Tag = switch (s[i]) {
                '(' => .l_paren,
                ')' => .r_paren,
                '{' => .l_brace,
                '}' => .r_brace,
                '[' => .l_bracket,
                ']' => .r_bracket,
                ',' => .comma,
                ';' => .semicolon,
                ':' => .colon,
                '?' => .question,
                '.' => .dot,
                '~' => .tilde,
                '!' => .bang,
                '@' => .at,
                '#' => .hash,
                '+' => .plus,
                '-' => .minus,
                '*' => .star,
                '/' => .slash,
                '%' => .percent,
                '&' => .ampersand,
                '|' => .pipe,
                '^' => .caret,
                '<' => .lt,
                '>' => .gt,
                '=' => .eq,
                else => null,
            };

            if (tag) |t| {
                self.offset += 1;
                self.loc.column += 1;
                return .{ .tag = t, .len = 1 };
            }
        }

        return null;
    }
};

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn classifyNumber(s: []const u8) Token.Tag {
    // Check for hex literal
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        if (s.len > 2 and (s[s.len-1] == 'u' or s[s.len-1] == 'U')) {
            return .uint_literal;
        }
        return .int_literal;
    }

    // Check for float/double
    var has_dot = false;
    var has_exponent = false;
    var has_float_suffix = false;

    for (s, 0..) |c, i| {
        if (c == '.') {
            has_dot = true;
        } else if (c == 'e' or c == 'E') {
            has_exponent = true;
        } else if ((c == 'f' or c == 'F') and i == s.len - 1) {
            has_float_suffix = true;
        }
    }

    if (has_dot or has_exponent or has_float_suffix) {
        if (has_float_suffix) {
            return .float_literal;
        }
        return .double_literal;
    }

    // Check for uint suffix
    if (s.len > 0 and (s[s.len-1] == 'u' or s[s.len-1] == 'U')) {
        return .uint_literal;
    }

    return .int_literal;
}

// Tests
test "tokenize simple operators" {
    const alloc = std.testing.allocator;
    const source = "+ - * / %";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 6), tokens.len); // 5 operators + eof
    try std.testing.expectEqual(Token.Tag.plus, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.minus, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.star, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.slash, tokens[3].tag);
    try std.testing.expectEqual(Token.Tag.percent, tokens[4].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[5].tag);
}

test "tokenize compound operators" {
    const alloc = std.testing.allocator;
    const source = "== != <= >= << >> ++ -- && ||";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 11), tokens.len);
    try std.testing.expectEqual(Token.Tag.eq_eq, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.bang_eq, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.lt_eq, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.gt_eq, tokens[3].tag);
    try std.testing.expectEqual(Token.Tag.lshift, tokens[4].tag);
    try std.testing.expectEqual(Token.Tag.rshift, tokens[5].tag);
    try std.testing.expectEqual(Token.Tag.plus_plus, tokens[6].tag);
    try std.testing.expectEqual(Token.Tag.minus_minus, tokens[7].tag);
    try std.testing.expectEqual(Token.Tag.ampersand_ampersand, tokens[8].tag);
    try std.testing.expectEqual(Token.Tag.pipe_pipe, tokens[9].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[10].tag);
}

test "tokenize keywords" {
    const alloc = std.testing.allocator;
    const source = "void float int vec4 mat4 uniform in out";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 9), tokens.len);
    try std.testing.expectEqual(Token.Tag.kw_void, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.kw_float, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.kw_int, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.kw_vec4, tokens[3].tag);
    try std.testing.expectEqual(Token.Tag.kw_mat4, tokens[4].tag);
    try std.testing.expectEqual(Token.Tag.kw_uniform, tokens[5].tag);
    try std.testing.expectEqual(Token.Tag.kw_in, tokens[6].tag);
    try std.testing.expectEqual(Token.Tag.kw_out, tokens[7].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[8].tag);
}

test "tokenize identifiers" {
    const alloc = std.testing.allocator;
    const source = "foo bar123 _baz";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[3].tag);

    try std.testing.expectEqualStrings("foo", source[tokens[0].start..][0..tokens[0].len]);
    try std.testing.expectEqualStrings("bar123", source[tokens[1].start..][0..tokens[1].len]);
    try std.testing.expectEqualStrings("_baz", source[tokens[2].start..][0..tokens[2].len]);
}

test "tokenize integer literals" {
    const alloc = std.testing.allocator;
    const source = "42 0xFF 100u 200U";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqual(Token.Tag.int_literal, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.int_literal, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.uint_literal, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.uint_literal, tokens[3].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[4].tag);
}

test "tokenize float literals" {
    const alloc = std.testing.allocator;
    const source = "1.0 .5 1e-3 1.5E+4 3.14f";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 6), tokens.len);
    try std.testing.expectEqual(Token.Tag.double_literal, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.double_literal, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.double_literal, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.double_literal, tokens[3].tag);
    try std.testing.expectEqual(Token.Tag.float_literal, tokens[4].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[5].tag);
}

test "tokenize line comment" {
    const alloc = std.testing.allocator;
    const source = "42 // comment\n43";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(Token.Tag.int_literal, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.int_literal, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[2].tag);

    try std.testing.expectEqualStrings("42", source[tokens[0].start..][0..tokens[0].len]);
    try std.testing.expectEqualStrings("43", source[tokens[1].start..][0..tokens[1].len]);
}

test "tokenize block comment" {
    const alloc = std.testing.allocator;
    const source = "42 /* block\ncomment */ 43";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(Token.Tag.int_literal, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.int_literal, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[2].tag);
}

test "tokenize preprocessor define" {
    const alloc = std.testing.allocator;
    const source = "#define FOO 42\nfloat x;";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 7), tokens.len);
    try std.testing.expectEqual(Token.Tag.pp_define, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.int_literal, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.kw_float, tokens[3].tag);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[4].tag);
    try std.testing.expectEqual(Token.Tag.semicolon, tokens[5].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[6].tag);
}

test "tokenize preprocessor ifdef" {
    const alloc = std.testing.allocator;
    const source = "#ifdef FOO\nfloat x;\n#endif";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 7), tokens.len);
    try std.testing.expectEqual(Token.Tag.pp_ifdef, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.kw_float, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[3].tag);
    try std.testing.expectEqual(Token.Tag.semicolon, tokens[4].tag);
    try std.testing.expectEqual(Token.Tag.pp_endif, tokens[5].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[6].tag);
}

test "tokenize location tracking" {
    const alloc = std.testing.allocator;
    const source = "a\nb\nc";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);

    try std.testing.expectEqual(@as(u32, 1), tokens[0].loc.line);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].loc.column);

    try std.testing.expectEqual(@as(u32, 2), tokens[1].loc.line);
    try std.testing.expectEqual(@as(u32, 1), tokens[1].loc.column);

    try std.testing.expectEqual(@as(u32, 3), tokens[2].loc.line);
    try std.testing.expectEqual(@as(u32, 1), tokens[2].loc.column);
}

test "tokenize eof" {
    const alloc = std.testing.allocator;
    const source = "";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(Token.Tag.eof, tokens[0].tag);
}

test "tokenize string literal" {
    const alloc = std.testing.allocator;
    const source = "\"hello world\"";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(Token.Tag.string_literal, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[1].tag);

    try std.testing.expectEqualStrings("\"hello world\"", source[tokens[0].start..][0..tokens[0].len]);
}

test "tokenize simple shader" {
    const alloc = std.testing.allocator;
    const source = "#version 430 core\nout vec4 fragColor;\nvoid main() {\n\tfragColor = vec4(1.0);\n}";
    const tokens = try tokenize(alloc, source);
    defer alloc.free(tokens);

    // Check first 10 token tags
    try std.testing.expectEqual(Token.Tag.pp_version, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.int_literal, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.kw_out, tokens[3].tag);
    try std.testing.expectEqual(Token.Tag.kw_vec4, tokens[4].tag);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[5].tag);
    try std.testing.expectEqual(Token.Tag.semicolon, tokens[6].tag);
    try std.testing.expectEqual(Token.Tag.kw_void, tokens[7].tag);
    try std.testing.expectEqual(Token.Tag.l_paren, tokens[9].tag);
    try std.testing.expectEqual(Token.Tag.r_paren, tokens[10].tag);
    try std.testing.expectEqual(Token.Tag.l_brace, tokens[11].tag);
}

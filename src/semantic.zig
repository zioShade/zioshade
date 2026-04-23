const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");

pub const Error = error{
    OutOfMemory,
    SemanticFailed,
    TypeMismatch,
    UndeclaredIdentifier,
    RedeclaredIdentifier,
    InvalidAssignment,
};

pub fn analyze(alloc: std.mem.Allocator, root: *ast.Root) Error!ir.Module {
    var analyzer = Analyzer{
        .alloc = alloc,
        .scopes = .empty,
        .globals = .{},
        .functions = .{},
        .types = .empty,
        .instructions = .{},
        .errors = .{},
    };
    defer analyzer.deinit();

    try analyzer.injectBuiltins();

    for (root.body) |node| {
        try analyzer.collectTopLevel(node);
    }

    for (root.body) |node| {
        if (node.tag == .function_decl) {
            try analyzer.analyzeFunction(node);
        }
    }

    if (analyzer.errors.items.len > 0) return error.SemanticFailed;

    return .{
        .functions = try analyzer.functions.toOwnedSlice(alloc),
        .globals = try analyzer.globals.toOwnedSlice(alloc),
        .types = analyzer.types,
        .entry_point = null,
        .alloc = alloc,
    };
}

const Symbol = struct {
    kind: enum { var_sym, param, func, type_sym },
    ty: ast.Type,
    ir_id: u32,
};

const Scope = std.StringHashMapUnmanaged(Symbol);

const Analyzer = struct {
    const TypedId = struct {
        ty: ast.Type,
        id: u32,
    };
    alloc: std.mem.Allocator,
    scopes: std.ArrayListUnmanaged(Scope),
    globals: std.ArrayListUnmanaged(ir.Global),
    functions: std.ArrayListUnmanaged(ir.Function),
    types: std.StringHashMapUnmanaged(ir.TypeDef),
    instructions: std.ArrayListUnmanaged(ir.Instruction),
    errors: std.ArrayListUnmanaged([]const u8),
    next_id: u32 = 1,

    fn deinit(self: *Analyzer) void {
        for (self.scopes.items) |*scope| scope.deinit(self.alloc);
        self.scopes.deinit(self.alloc);
        self.globals.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        for (self.errors.items) |msg| self.alloc.free(msg);
        self.errors.deinit(self.alloc);
        self.instructions.deinit(self.alloc);
    }

    fn allocId(self: *Analyzer) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn pushScope(self: *Analyzer) !void {
        try self.scopes.append(self.alloc, .empty);
    }

    fn popScope(self: *Analyzer) void {
        var scope = self.scopes.pop() orelse return;
        scope.deinit(self.alloc);
    }

    fn declare(self: *Analyzer, name: []const u8, sym: Symbol) !void {
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.put(self.alloc, name, sym);
    }

    fn lookup(self: *Analyzer, name: []const u8) ?Symbol {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |sym| return sym;
        }
        return null;
    }

    fn injectBuiltins(self: *Analyzer) !void {
        try self.pushScope();

        try self.declare("gl_FragCoord", .{
            .kind = .var_sym,
            .ty = .vec4,
            .ir_id = self.allocId(),
        });

        try self.declare("gl_FragColor", .{
            .kind = .var_sym,
            .ty = .vec4,
            .ir_id = self.allocId(),
        });

        const math_funcs = .{
            "abs",   "acos",  "asin",      "atan",    "atan2",
            "ceil",  "clamp", "cos",       "cosh",    "cross",
            "degrees", "determinant", "distance", "dot",
            "exp",   "exp2",  "faceforward", "floor", "fract",
            "inversesqrt", "length", "log", "log2",
            "max",   "min",   "mix",       "mod",     "normalize",
            "pow",   "radians", "reflect", "refract",
            "round", "sign",  "sin",       "sinh",
            "smoothstep", "sqrt", "step",  "tan",     "tanh",
            "transpose",  "trunc",
        };
        inline for (math_funcs) |name| {
            try self.declare(name, .{
                .kind = .func,
                .ty = .void,
                .ir_id = self.allocId(),
            });
        }

        try self.declare("texture", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
        try self.declare("texture2D", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
        try self.declare("textureLod", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
        try self.declare("texelFetch", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
    }

    fn collectTopLevel(self: *Analyzer, node: ast.Node) !void {
        switch (node.tag) {
            .var_decl, .uniform_decl, .in_decl, .out_decl => {
                const ir_id = self.allocId();
                const storage_class: ir.SPIRVStorageClass = switch (node.tag) {
                    .in_decl => .input,
                    .out_decl => .output,
                    .uniform_decl => .uniform,
                    else => .function,
                };
                try self.globals.append(self.alloc, .{
                    .name = node.data.name,
                    .ty = node.data.ty orelse .void,
                    .qualifier = node.data.qualifier orelse .{},
                    .layout = node.data.layout,
                    .storage_class = storage_class,
                    .result_id = ir_id,
                });
                try self.declare(node.data.name, .{
                    .kind = .var_sym,
                    .ty = node.data.ty orelse .void,
                    .ir_id = ir_id,
                });
            },
            .struct_decl => {
                const name = node.data.name;
                const td = ir.TypeDef{
                    .name = name,
                    .members = node.data.members,
                    .size_bytes = 0,
                };
                const owned_name = try self.alloc.dupe(u8, name);
                try self.types.put(self.alloc, owned_name, td);
                try self.declare(name, .{
                    .kind = .type_sym,
                    .ty = .{ .named = name },
                    .ir_id = self.allocId(),
                });
            },
            .function_decl, .function_prototype => {
                try self.declare(node.data.name, .{
                    .kind = .func,
                    .ty = node.data.ty orelse .void,
                    .ir_id = self.allocId(),
                });
            },
            else => {},
        }
    }

    fn analyzeFunction(self: *Analyzer, node: ast.Node) !void {
        try self.pushScope();

        for (node.data.params) |param| {
            try self.declare(param.name, .{
                .kind = .param,
                .ty = param.ty,
                .ir_id = self.allocId(),
            });
        }

        self.instructions.clearRetainingCapacity();

        for (node.data.children) |child| {
            try self.analyzeStatement(child);
        }

        const func = ir.Function{
            .name = node.data.name,
            .return_type = node.data.ty orelse .void,
            .params = node.data.params,
            .body = try self.instructions.toOwnedSlice(self.alloc),
            .locals = &.{},
            .result_id = 0,
        };
        try self.functions.append(self.alloc, func);

        self.popScope();
    }

    fn analyzeStatement(self: *Analyzer, node: ast.Node) !void {
        switch (node.tag) {
            .var_decl => {
                const ir_id = self.allocId();
                const ty = node.data.ty orelse .void;
                try self.declare(node.data.name, .{
                    .kind = .var_sym,
                    .ty = ty,
                    .ir_id = ir_id,
                });
                if (node.data.children.len > 0) {
                    const init_tid = try self.analyzeExpression(node.data.children[0]);
                    if (!self.typesCompatible(ty, init_tid.ty)) {
                        return error.TypeMismatch;
                    }
                }
            },
            .block => {
                try self.pushScope();
                for (node.data.children) |child| {
                    try self.analyzeStatement(child);
                }
                self.popScope();
            },
            .if_stmt => {
                if (node.data.children.len > 0) {
                    _ = try self.analyzeExpression(node.data.children[0]);
                }
                if (node.data.children.len > 1) try self.analyzeStatement(node.data.children[1]);
                if (node.data.children.len > 2) try self.analyzeStatement(node.data.children[2]);
            },
            .for_stmt => {
                try self.pushScope();
                for (node.data.children) |child| {
                    try self.analyzeStatement(child);
                }
                self.popScope();
            },
            .while_stmt, .do_while_stmt => {
                for (node.data.children) |child| {
                    try self.analyzeStatement(child);
                }
            },
            .return_stmt => {
                if (node.data.children.len > 0) {
                    _ = try self.analyzeExpression(node.data.children[0]);
                }
            },
            .discard_stmt, .break_stmt, .continue_stmt => {},
            .expr_stmt => {
                if (node.data.children.len > 0) {
                    _ = try self.analyzeExpression(node.data.children[0]);
                }
            },
            else => {},
        }
    }

    fn analyzeExpression(self: *Analyzer, node: ast.Node) Error!TypedId {
        switch (node.tag) {
            .int_literal => return .{ .ty = .int, .id = self.allocId() },
            .uint_literal => return .{ .ty = .uint, .id = self.allocId() },
            .float_literal => return .{ .ty = .float, .id = self.allocId() },
            .bool_literal => return .{ .ty = .bool, .id = self.allocId() },
            .identifier => {
                if (self.lookup(node.data.name)) |sym| return .{ .ty = sym.ty, .id = sym.ir_id };
                return error.UndeclaredIdentifier;
            },
            .binary_op => {
                if (node.data.children.len < 2) return error.SemanticFailed;
                const left_tid = try self.analyzeExpression(node.data.children[0]);
                const right_tid = try self.analyzeExpression(node.data.children[1]);
                return .{ .ty = self.promoteTypes(left_tid.ty, right_tid.ty) orelse return error.TypeMismatch, .id = self.allocId() };
            },
            .unary_op => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                const tid = try self.analyzeExpression(node.data.children[0]);
                return .{ .ty = tid.ty, .id = self.allocId() };
            },
            .assign_op, .compound_assign => {
                if (node.data.children.len < 2) return error.SemanticFailed;
                _ = try self.analyzeExpression(node.data.children[0]);
                _ = try self.analyzeExpression(node.data.children[1]);
                return .{ .ty = .void, .id = self.allocId() };
            },
            .func_call => {
                _ = self.lookup(node.data.name);
                for (node.data.children) |arg| {
                    _ = try self.analyzeExpression(arg);
                }
                if (self.lookup(node.data.name)) |sym| {
                    return .{ .ty = sym.ty, .id = self.allocId() };
                }
                return .{ .ty = .void, .id = self.allocId() };
            },
            .type_constructor => {
                for (node.data.children) |arg| {
                    _ = try self.analyzeExpression(arg);
                }
                return .{ .ty = node.data.ty orelse .void, .id = self.allocId() };
            },
            .ternary_op => {
                if (node.data.children.len < 3) return error.SemanticFailed;
                _ = try self.analyzeExpression(node.data.children[0]);
                const then_tid = try self.analyzeExpression(node.data.children[1]);
                const else_tid = try self.analyzeExpression(node.data.children[2]);
                return .{ .ty = self.promoteTypes(then_tid.ty, else_tid.ty) orelse then_tid.ty, .id = self.allocId() };
            },
            .member_access, .swizzle_access => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                const base_tid = try self.analyzeExpression(node.data.children[0]);
                if (base_tid.ty.isVector()) return .{ .ty = .float, .id = self.allocId() };
                return base_tid;
            },
            .index_access => {
                if (node.data.children.len < 2) return error.SemanticFailed;
                _ = try self.analyzeExpression(node.data.children[1]);
                const base_tid = try self.analyzeExpression(node.data.children[0]);
                return .{ .ty = base_tid.ty, .id = self.allocId() };
            },
            .post_increment, .post_decrement, .pre_increment, .pre_decrement => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                const tid = try self.analyzeExpression(node.data.children[0]);
                return .{ .ty = tid.ty, .id = self.allocId() };
            },
            .group => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                return self.analyzeExpression(node.data.children[0]);
            },
            else => return .{ .ty = .void, .id = self.allocId() },
        }
    }

    fn promoteTypes(self: *Analyzer, a: ast.Type, b: ast.Type) ?ast.Type {
        _ = self;
        if (std.meta.eql(a, b)) return a;
        if (a == .float or b == .float) return .float;
        if (a == .double or b == .double) return .double;
        if (a == .uint or b == .uint) return .uint;
        return null;
    }

    fn typesCompatible(self: *Analyzer, target: ast.Type, source: ast.Type) bool {
        _ = self;
        if (std.meta.eql(target, source)) return true;
        if (target == .float and source.isScalar()) return true;
        if (target == .uint and source == .int) return true;
        return false;
    }
};

// ── Tests ─────────────────────────────────────────────────────

const testing = std.testing;
const lexer = @import("lexer.zig");
const preprocessor = @import("preprocessor.zig");
const parser = @import("parser.zig");

test "semantic: type error on incompatible types" {
    const source = "void main() { bool b = 1.0 + true; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    const result = analyze(testing.allocator, &root);
    try testing.expect(result == error.TypeMismatch or result == error.SemanticFailed);
}

test "semantic: find declared variable" {
    const source = "void main() { float x = 1.0; float y = x; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();
}

test "semantic: undeclared identifier" {
    const source = "void main() { float y = x; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    const result = analyze(testing.allocator, &root);
    try testing.expect(result == error.UndeclaredIdentifier);
}

test "semantic: builtin gl_FragCoord available" {
    const source = "void main() { vec4 pos = gl_FragCoord; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();
}

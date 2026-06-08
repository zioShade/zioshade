//! Compatibility layer for Zig 0.15.2 and 0.16.0.
//!
//! Uses comptime (`is_0_16`) to select the correct API branch.
//! The untaken branch is dead-code-eliminated, so no 0.16-only types
//! leak into 0.15 builds (and vice versa).
//!
//! All APIs work on both 0.15.2 and 0.16.0.

const std = @import("std");
const builtin = @import("builtin");

/// Comptime flag: true when compiling with Zig >= 0.16.0.
pub const is_0_16 = builtin.zig_version.minor >= 16;

// ---- Allocator ----

pub const Gpa = std.heap.DebugAllocator;

// ---- File system types ----

pub const Dir = if (is_0_16) std.Io.Dir else std.fs.Dir;
pub const File = if (is_0_16) std.Io.File else std.fs.File;
pub const max_path_bytes = std.fs.max_path_bytes;

// ---- I/O context ----

pub const IoType = if (is_0_16) std.Io else void;

/// I/O context for test code.
pub fn testIo() IoType {
    if (is_0_16) {
        return std.testing.io;
    }
}

/// I/O context wrapper for main/executable code.
pub fn MainIo() type {
    return if (is_0_16) struct {
        inner: std.Io.Threaded,
        pub fn init(gpa: std.mem.Allocator) @This() {
            return .{ .inner = std.Io.Threaded.init(gpa, .{}) };
        }
        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
        }
        pub fn io(self: *@This()) std.Io {
            return self.inner.io();
        }
    } else struct {
        pub fn init(_: std.mem.Allocator) @This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn io(_: *@This()) void {}
    };
}

// ---- Random ----

threadlocal var prng_state: if (is_0_16) std.Random.DefaultPrng else void = if (is_0_16) .init(0) else {};
threadlocal var prng_inited: bool = false;

fn ensurePrng() void {
    if (!prng_inited) {
        if (is_0_16) {
            // Simple deterministic seed. For non-crypto purposes this is fine.
            // The seed varies per compilation due to builtin.zig_version.
            const seed: u64 = 0xdeadbeefcafebabe;
            prng_state = std.Random.DefaultPrng.init(seed);
        }
        prng_inited = true;
    }
}

pub fn randomInt(comptime T: type) T {
    if (is_0_16) {
        ensurePrng();
        return prng_state.random().int(T);
    } else {
        return std.crypto.random.int(T);
    }
}

// ---- CWD ----

pub fn cwd() Dir {
    if (is_0_16) {
        return std.Io.Dir.cwd();
    } else {
        return std.fs.cwd();
    }
}

// ---- Dir operations ----

pub const CreateFileFlags = if (is_0_16) std.Io.Dir.CreateFileOptions else std.fs.File.CreateFlags;
pub const OpenFileFlags = if (is_0_16) std.Io.Dir.OpenFileOptions else std.fs.File.OpenFlags;
pub const OpenDirFlags = if (is_0_16) std.Io.Dir.OpenOptions else std.fs.Dir.OpenOptions;

pub fn dirCreateFile(io: IoType, dir: Dir, sub_path: []const u8, flags: CreateFileFlags) !File {
    if (is_0_16) {
        return dir.createFile(io, sub_path, flags);
    } else {
        return dir.createFile(sub_path, flags);
    }
}

pub fn dirOpenFile(io: IoType, dir: Dir, sub_path: []const u8, flags: OpenFileFlags) !File {
    if (is_0_16) {
        return dir.openFile(io, sub_path, flags);
    } else {
        return dir.openFile(sub_path, flags);
    }
}

pub fn dirMakePath(io: IoType, dir: Dir, sub_path: []const u8) !void {
    if (is_0_16) {
        return dir.createDirPath(io, sub_path);
    } else {
        return dir.makePath(sub_path);
    }
}

pub fn dirDeleteFile(io: IoType, dir: Dir, sub_path: []const u8) !void {
    if (is_0_16) {
        return dir.deleteFile(io, sub_path);
    } else {
        return dir.deleteFile(sub_path);
    }
}

pub fn dirOpenDir(io: IoType, dir: Dir, sub_path: []const u8, flags: OpenDirFlags) !Dir {
    if (is_0_16) {
        return dir.openDir(io, sub_path, flags);
    } else {
        return dir.openDir(sub_path, flags);
    }
}

pub fn dirClose(io: IoType, dir: Dir) void {
    if (is_0_16) {
        dir.close(io);
    } else {
        var mut_dir = dir;
        mut_dir.close();
    }
}

pub fn dirWriteFile(io: IoType, dir: Dir, sub_path: []const u8, data: []const u8) !void {
    if (is_0_16) {
        return dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    } else {
        return dir.writeFile(.{ .sub_path = sub_path, .data = data });
    }
}

pub fn dirReadFileAlloc(io: IoType, dir: Dir, alloc: std.mem.Allocator, sub_path: []const u8, limit: usize) ![]u8 {
    if (is_0_16) {
        return dir.readFileAlloc(io, sub_path, alloc, @enumFromInt(limit));
    } else {
        return dir.readFileAlloc(alloc, sub_path, limit);
    }
}

// ---- File operations ----

pub fn fileClose(io: IoType, file: File) void {
    if (is_0_16) {
        file.close(io);
    } else {
        file.close();
    }
}

pub fn fileWriteAll(io: IoType, file: File, bytes: []const u8) !void {
    if (is_0_16) {
        return file.writePositionalAll(io, bytes, 0);
    } else {
        return file.writeAll(bytes);
    }
}

pub fn fileReadToEndAlloc(io: IoType, file: File, alloc: std.mem.Allocator, limit: usize) ![]u8 {
    if (is_0_16) {
        var buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        return try file_reader.interface.allocRemaining(alloc, .unlimited);
    } else {
        return try file.readToEndAlloc(alloc, limit);
    }
}

pub fn fileRealpath(io: IoType, dir: Dir, sub_path: []const u8, buffer: []u8) ![]u8 {
    if (is_0_16) {
        return dir.realpath(io, sub_path, buffer);
    } else {
        return dir.realpath(sub_path, buffer);
    }
}

// ---- Walker ----

pub fn dirWalk(dir: Dir, alloc: std.mem.Allocator) !if (is_0_16) std.Io.Dir.Walker else std.fs.Dir.Walker {
    if (is_0_16) {
        return dir.walk(alloc);
    } else {
        return dir.walk(alloc);
    }
}

pub fn walkerNext(io: IoType, walker: anytype) !?@TypeOf(walker.*).Entry {
    if (is_0_16) {
        return walker.next(io);
    } else {
        return walker.next();
    }
}

// ---- Process / Args ----

threadlocal var main_init_storage: if (is_0_16) std.process.Init.Minimal else void = if (is_0_16) undefined else {};
threadlocal var main_init_set: bool = false;

/// The main function input type.
/// On 0.15: void. On 0.16: std.process.Init.Minimal.
pub const MainInit = if (is_0_16) std.process.Init.Minimal else void;

/// Store init for later retrieval. Call at start of main on 0.16.
pub fn setMainInit(init: MainInit) void {
    if (is_0_16) {
        main_init_storage = init;
        main_init_set = true;
    }
}

/// Get command-line arguments.
pub fn argsAlloc(alloc: std.mem.Allocator) ![]const [:0]const u8 {
    if (is_0_16) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var it = try main_init_storage.args.iterateAllocator(arena.allocator());
        defer it.deinit();
        var list: std.array_list.Aligned([:0]const u8, null) = .empty;
        errdefer {
            for (list.items) |a| alloc.free(a);
            list.deinit(alloc);
        }
        while (it.next()) |arg| {
            const owned = try alloc.dupeZ(u8, arg);
            try list.append(alloc, owned);
        }
        return try list.toOwnedSlice(alloc);
    } else {
        return std.process.argsAlloc(alloc);
    }
}

/// Free args allocated by argsAlloc.
pub fn argsFree(alloc: std.mem.Allocator, args: []const [:0]const u8) void {
    if (is_0_16) {
        for (args) |a| alloc.free(a);
        alloc.free(args);
    } else {
        std.process.argsFree(alloc, args);
    }
}

// ---- Process execution ----

pub const ProcessResult = struct {
    term: ProcessTerm,
    stdout: []u8,
    stderr: []u8,
};

pub const ProcessTerm = union(enum) {
    exited: u8,

    pub fn exitedCode(self: ProcessTerm) ?u8 {
        if (self == .exited) return self.exited;
        return null;
    }
};

pub fn processRun(io: IoType, alloc: std.mem.Allocator, argv: []const []const u8) !ProcessResult {
    if (is_0_16) {
        const result = std.process.run(alloc, io, .{ .argv = argv }) catch |err| {
            if (err == error.FileNotFound) return error.FileNotFound;
            return err;
        };
        return .{
            .term = .{ .exited = switch (result.term) {
                .exited => |code| code,
                else => 1,
            } },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    } else {
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = argv,
        });
        return .{
            .term = .{ .exited = switch (result.term) {
                .Exited => |code| code,
                else => 1,
            } },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }
}

// ---- Tooling paths ----

/// Resolve a Vulkan SDK CLI tool by basename. Prefer `$VULKAN_SDK/Bin/<tool>[.exe]`
/// (`.exe` appended only on Windows); fall back to the bare name on PATH when
/// VULKAN_SDK is unset or set-but-empty. Caller owns the returned slice.
///
/// Keeps machine-specific absolute SDK paths out of the tree so tests/tools stay
/// portable across machines / CI / non-Windows. Callers that spawn the result
/// should degrade a spawn failure to a skip rather than a hard failure.
pub fn resolveVulkanTool(allocator: std.mem.Allocator, tool: []const u8) ![]const u8 {
    const exe = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "{s}.exe", .{tool})
    else
        try allocator.dupe(u8, tool);
    if (std.process.getEnvVarOwned(allocator, "VULKAN_SDK")) |sdk| {
        defer allocator.free(sdk);
        // Treat a set-but-empty value as unset so we fall back to PATH rather
        // than building a bogus relative "Bin/<tool>" path.
        if (sdk.len == 0) return exe;
        defer allocator.free(exe);
        return try std.fs.path.join(allocator, &.{ sdk, "Bin", exe });
    } else |err| switch (err) {
        // Not set — fall back to PATH lookup by bare name.
        error.EnvironmentVariableNotFound => return exe,
        // Propagate real failures (OOM; InvalidWtf8 can't occur for an ASCII key).
        else => |e| {
            allocator.free(exe);
            return e;
        },
    }
}

/// Resolve the spirv-val executable; thin wrapper over `resolveVulkanTool`.
/// Caller owns the returned slice and must free it.
pub fn resolveSpirvVal(allocator: std.mem.Allocator) ![]const u8 {
    return resolveVulkanTool(allocator, "spirv-val");
}

// ---- List writer ----

pub fn ListWriterPtr(comptime T: type) type {
    return struct {
        list: *std.ArrayList(T),
        alloc: std.mem.Allocator,

        const Self = @This();

        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
            return self.list.print(self.alloc, fmt, args);
        }

        pub fn writeAll(self: Self, data: []const T) !void {
            return self.list.appendSlice(self.alloc, data);
        }
    };
}

pub fn listWriter(list: *std.ArrayList(u8), alloc: std.mem.Allocator) ListWriterPtr(u8) {
    return .{ .list = list, .alloc = alloc };
}

// ---- Stack buffer writer ----

pub fn StackBufWriter(comptime size: usize) type {
    return struct {
        buf: [size]u8,
        pos: usize,

        const Self = @This();

        pub fn init() Self {
            return .{ .buf = undefined, .pos = 0 };
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
            if (self.pos >= self.buf.len) return;
            const result = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch return;
            self.pos += result.len;
        }

        pub fn writeAll(self: *Self, data: []const u8) void {
            if (self.pos + data.len > self.buf.len) {
                self.pos = self.buf.len;
                return;
            }
            @memcpy(self.buf[self.pos..][0..data.len], data);
            self.pos += data.len;
        }

        pub fn written(self: *const Self) []const u8 {
            return self.buf[0..self.pos];
        }

        pub fn overflowed(self: *const Self) bool {
            return self.pos >= self.buf.len;
        }
    };
}

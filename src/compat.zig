//! Compatibility layer across supported Zig versions.
//!
//! Selection is by CAPABILITY DETECTION, not version number, so a newer Zig
//! that keeps an API shape works untouched (forward compatibility). The untaken
//! comptime branch is not analyzed, so no version-only types leak across builds.
//!
//! Supported range: Zig 0.15.2 is the hard floor (enforced below); the tested
//! window is the last three releases (see the README version policy). Anything
//! newer is best-effort. Mark each version-specific shim with a `COMPAT(x.y)`
//! comment noting when it can be deleted once the floor moves past it.

const std = @import("std");
const builtin = @import("builtin");

/// Hard floor. Anything older than this is unsupported and fails to compile
/// here with an actionable message rather than a cryptic stdlib error later.
pub const min_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };
comptime {
    if (builtin.zig_version.order(min_zig) == .lt) {
        @compileError("zioshade requires Zig 0.15.2 or newer. See the README.");
    }
}

/// True when the new `std.Io` filesystem API is present (Zig 0.16+). Detected by
/// capability (`std.Io.Dir` exists), not by version number: 0.15.2 has `std.Io`
/// but no `std.Io.Dir`, and a future release that keeps `std.Io.Dir` still
/// selects this branch with no code change. COMPAT(0.15): when the floor moves
/// to 0.16, this is always true and the `else` branches below can be deleted.
pub const is_0_16 = @hasDecl(std, "Io") and @hasDecl(std.Io, "Dir");

// ---- Allocator ----

pub const Gpa = std.heap.DebugAllocator;

// ---- File system types ----

pub const Dir = if (is_0_16) std.Io.Dir else std.fs.Dir;
pub const File = if (is_0_16) std.Io.File else std.fs.File;
pub const max_path_bytes = std.fs.max_path_bytes;

// ---- I/O context ----

pub const IoType = if (is_0_16) std.Io else void;

/// I/O context wrapper for main/executable code.
///
/// On 0.16 the Threaded I/O carries the process environment so that spawning a
/// child by bare name (e.g. "spirv-val") resolves it against PATH. The env is
/// sourced by context: the test runner installs it at `std.testing.environ` in
/// test binaries, and `setMainInit` stashes it from `std.process.Init` for
/// executables. Without it, `std.process.run` takes argv[0] literally and every
/// bare-name oracle spawn fails with FileNotFound (0.15's POSIX exec searched
/// PATH regardless, which is why this only bites on 0.16). COMPAT(0.15).
pub fn MainIo() type {
    return if (is_0_16) struct {
        inner: std.Io.Threaded,
        pub fn init(gpa: std.mem.Allocator) @This() {
            const environ = if (builtin.is_test)
                std.testing.environ
            else if (main_init_set)
                main_init_storage.environ
            else
                std.process.Environ.empty;
            return .{ .inner = std.Io.Threaded.init(gpa, .{ .environ = environ }) };
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
//
// `randomInt` names temp files that concurrently-running test binaries must not
// collide on (the whole reason the callers moved off a shared path). On 0.15
// this is std.crypto.random. On 0.16 crypto.random was removed and the clock
// moved behind std.Io, so we seed a PRNG from entropy reachable without an Io
// context: the address of a stack local (ASLR differs per process, and stacks
// differ per thread) mixed with a process-global atomic counter (distinct per
// call). A fixed seed would defeat the point by handing every process the same
// "random" name. COMPAT(0.15): revisit if a non-Io entropy source returns.

threadlocal var prng_state: if (is_0_16) std.Random.DefaultPrng else void = if (is_0_16) .init(0) else {};
threadlocal var prng_inited: bool = false;
var seed_counter: if (is_0_16) std.atomic.Value(u64) else void = if (is_0_16) .init(0) else {};

fn ensurePrng() void {
    if (!prng_inited) {
        if (is_0_16) {
            var stack_anchor: u8 = 0;
            const addr: u64 = @intFromPtr(&stack_anchor);
            const counter = seed_counter.fetchAdd(1, .monotonic);
            var seed = addr ^ 0x9e3779b97f4a7c15;
            seed = seed *% 0xff51afd7ed558ccd;
            seed ^= counter;
            // Cross-process entropy: with ASLR disabled two processes can share
            // both the stack address AND counter=0, yielding an identical seed and
            // a temp-file collision. Mixing in the current thread id breaks the
            // tie: on Linux the main thread's id is the pid, so it varies per
            // process. Cross-platform via std.Thread; no libc dependency.
            const tid = std.Thread.getCurrentId();
            seed ^= (@as(u64, tid) *% 0x100000001b3);
            seed = seed *% 0xc4ceb9fe1a85ec53;
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

// ---- Path-based one-shot file helpers ----
//
// These hide the whole 0.15/0.16 filesystem-plus-Io split from callers: on 0.16
// file IO needs a std.Io context, which they construct and tear down internally;
// on 0.15 the io is void and these fall through to plain std.fs. Callers pass
// only an allocator and a path, so the rest of the source stays version-agnostic.
// One-shot (a fresh io per call), so intended for cold paths like reading a
// shader or an #include, not hot loops. COMPAT(0.15): keep once the floor moves.

/// Read an entire file at `path` (relative to cwd) into caller-owned bytes.
pub fn readFileByPath(alloc: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var main_io = MainIo().init(alloc);
    defer main_io.deinit();
    return dirReadFileAlloc(main_io.io(), cwd(), alloc, path, limit);
}

/// Write `data` to `path` (relative to cwd), creating or truncating it.
pub fn writeFileByPath(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    var main_io = MainIo().init(alloc);
    defer main_io.deinit();
    return dirWriteFile(main_io.io(), cwd(), path, data);
}

/// Delete the file at `path` (relative to cwd).
pub fn deleteFileByPath(alloc: std.mem.Allocator, path: []const u8) !void {
    var main_io = MainIo().init(alloc);
    defer main_io.deinit();
    return dirDeleteFile(main_io.io(), cwd(), path);
}

/// Read all of stdin into caller-owned bytes (up to `limit`). Hides the
/// 0.15/0.16 File + Io split: on 0.16 stdin reads need a std.Io context,
/// constructed internally over the page allocator (fine for a CLI one-shot).
pub fn readStdinAlloc(alloc: std.mem.Allocator, limit: usize) ![]u8 {
    if (is_0_16) {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const in = std.Io.File.stdin();
        var buf: [4096]u8 = undefined;
        var reader = in.reader(threaded.io(), &buf);
        return try reader.interface.allocRemaining(alloc, @enumFromInt(limit));
    } else {
        const in = std.fs.File.stdin();
        return try in.readToEndAlloc(alloc, limit);
    }
}

/// Create (or truncate) the file at absolute `abs_path` and write `data`.
/// Hides the 0.15/0.16 split (createFileAbsolute moved behind std.Io on 0.16).
/// Intended for tests/tools that stage oracle inputs under the system temp dir.
pub fn writeFileAbsolute(alloc: std.mem.Allocator, abs_path: []const u8, data: []const u8) !void {
    if (is_0_16) {
        var main_io = MainIo().init(alloc);
        defer main_io.deinit();
        const io = main_io.io();
        const file = try std.Io.Dir.createFileAbsolute(io, abs_path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, data, 0);
    } else {
        const file = try std.fs.createFileAbsolute(abs_path, .{});
        defer file.close();
        try file.writeAll(data);
    }
}

/// Delete the file at absolute `abs_path`. Hides the 0.15/0.16 split. Intended
/// to clean up oracle temp files staged with `writeFileAbsolute`.
pub fn deleteFileAbsolute(alloc: std.mem.Allocator, abs_path: []const u8) !void {
    if (is_0_16) {
        var main_io = MainIo().init(alloc);
        defer main_io.deinit();
        return std.Io.Dir.deleteFileAbsolute(main_io.io(), abs_path);
    } else {
        return std.fs.deleteFileAbsolute(abs_path);
    }
}

/// Create the directory at absolute `abs_path`. Hides the 0.15/0.16 split
/// (std.fs.makeDirAbsolute became std.Io.Dir.createDirAbsolute on 0.16, behind
/// std.Io). Propagates the raw error so callers can still match
/// `error.PathAlreadyExists` (present in both error sets).
pub fn makeDirAbsolute(alloc: std.mem.Allocator, abs_path: []const u8) !void {
    if (is_0_16) {
        var main_io = MainIo().init(alloc);
        defer main_io.deinit();
        return std.Io.Dir.createDirAbsolute(main_io.io(), abs_path, .default_dir);
    } else {
        return std.fs.makeDirAbsolute(abs_path);
    }
}

/// Read the entire file at absolute `abs_path` into caller-owned bytes.
/// Hides the 0.15/0.16 split (openFileAbsolute moved behind std.Io on 0.16).
pub fn readFileAbsolute(alloc: std.mem.Allocator, abs_path: []const u8, limit: usize) ![]u8 {
    if (is_0_16) {
        var main_io = MainIo().init(alloc);
        defer main_io.deinit();
        const io = main_io.io();
        const file = try std.Io.Dir.openFileAbsolute(io, abs_path, .{ .mode = .read_only });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        return try file_reader.interface.allocRemaining(alloc, @enumFromInt(limit));
    } else {
        const file = try std.fs.openFileAbsolute(abs_path, .{ .mode = .read_only });
        defer file.close();
        return try file.readToEndAlloc(alloc, limit);
    }
}

/// Return the OS temporary directory as a caller-owned absolute path, with any
/// trailing separator stripped. Honors TMPDIR/TEMP/TMP (CI runners and Windows
/// set these to a user-writable location), falling back to a platform default
/// when the environment is unreadable, as on 0.16 where env access sits behind
/// std.Io and getEnvVarOwned degrades to null.
///
/// Tests and dev tools stage oracle input/output files here. A hardcoded "/tmp"
/// is not a valid path on Windows (createFileAbsolute fails with FileNotFound /
/// OBJECT_PATH_NOT_FOUND), which is why this indirection exists.
pub fn tempDir(alloc: std.mem.Allocator) ![]u8 {
    // On Windows the runner sets TEMP/TMP; POSIX conventionally uses TMPDIR.
    const names = if (builtin.os.tag == .windows)
        [_][]const u8{ "TEMP", "TMP" }
    else
        [_][]const u8{ "TMPDIR", "TMP" };
    for (names) |name| {
        if (getEnvVarOwned(alloc, name)) |val| {
            defer alloc.free(val);
            // Strip trailing separators so a subsequent path.join is clean.
            const seps = if (builtin.os.tag == .windows) "\\/" else "/";
            var end = val.len;
            while (end > 0 and std.mem.indexOfScalar(u8, seps, val[end - 1]) != null) end -= 1;
            if (end == 0) continue; // unset, empty, or all-separators: try next
            return alloc.dupe(u8, val[0..end]);
        }
    }
    return alloc.dupe(u8, if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else "/tmp");
}

/// Join the OS temp directory with `name` into a caller-owned absolute path.
/// Convenience over `tempDir` for the common "stage a file under temp" case;
/// picks the correct path separator for the host so callers stay portable.
pub fn tempFilePath(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const dir = try tempDir(alloc);
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, name });
}

/// `tempFilePath` with a formatted basename, so the many test/tool sites that
/// build a temp name from a shader name or random suffix stay a single call.
/// The formatted basename is freed internally; only the joined path is returned.
pub fn tempFilePathFmt(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const base = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(base);
    return tempFilePath(alloc, base);
}

/// Write `bytes` to stdout. Hides the 0.15/0.16 File + Io split: on 0.16 stdout
/// writes need a std.Io context, constructed internally over the page allocator
/// (fine for a CLI one-shot); on 0.15 this is a plain File.writeAll. Allocator
/// free so callers that only have a path/data pair need not thread one through.
pub fn writeStdout(bytes: []const u8) !void {
    if (is_0_16) {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const out = std.Io.File.stdout();
        try out.writeStreamingAll(threaded.io(), bytes);
    } else {
        const out = std.fs.File.stdout();
        try out.writeAll(bytes);
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
        return try file_reader.interface.allocRemaining(alloc, @enumFromInt(limit));
    } else {
        return try file.readToEndAlloc(alloc, limit);
    }
}

// ---- Walker ----

pub fn dirWalk(dir: Dir, alloc: std.mem.Allocator) !if (is_0_16) std.Io.Dir.Walker else std.fs.Dir.Walker {
    return dir.walk(alloc);
}

pub fn walkerNext(io: IoType, walker: anytype) !?@TypeOf(walker.*).Entry {
    if (is_0_16) {
        return walker.next(io);
    } else {
        return walker.next();
    }
}

/// A directory entry surfaced by `walkDirAlloc`: the caller-owned path is
/// relative to cwd (the walked dir joined with the walk-relative path), so it
/// can be handed straight to `readFileByPath`.
pub const WalkEntry = struct {
    path: []u8,
    is_file: bool,
};

/// Recursively list the entries under `dir_path` (relative to cwd), returning a
/// caller-owned slice of `WalkEntry`. Hides the 0.15/0.16 Dir/Io + Walker split
/// so dev tools that scan a fixture directory need not thread an Io context or a
/// live Dir handle through their logic — they iterate the slice and read each
/// file by path. Free with `freeWalkEntries`.
pub fn walkDirAlloc(alloc: std.mem.Allocator, dir_path: []const u8) ![]WalkEntry {
    var list: std.ArrayListUnmanaged(WalkEntry) = .empty;
    errdefer {
        for (list.items) |e| alloc.free(e.path);
        list.deinit(alloc);
    }
    if (is_0_16) {
        var main_io = MainIo().init(alloc);
        defer main_io.deinit();
        const io = main_io.io();
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(alloc);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            const full = try std.fs.path.join(alloc, &.{ dir_path, entry.path });
            try list.append(alloc, .{ .path = full, .is_file = entry.kind == .file });
        }
    } else {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(alloc);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            const full = try std.fs.path.join(alloc, &.{ dir_path, entry.path });
            try list.append(alloc, .{ .path = full, .is_file = entry.kind == .file });
        }
    }
    return list.toOwnedSlice(alloc);
}

/// Free the slice returned by `walkDirAlloc`, including each entry path.
pub fn freeWalkEntries(alloc: std.mem.Allocator, entries: []WalkEntry) void {
    for (entries) |e| alloc.free(e.path);
    alloc.free(entries);
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

/// Command-line argument list. The inner slices are non-const so this matches
/// 0.15's `std.process.argsFree` parameter type; reads still coerce to const.
pub const Args = []const [:0]u8;

/// Get command-line arguments.
pub fn argsAlloc(alloc: std.mem.Allocator) !Args {
    if (is_0_16) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var it = try main_init_storage.args.iterateAllocator(arena.allocator());
        defer it.deinit();
        var list: std.array_list.Aligned([:0]u8, null) = .empty;
        errdefer {
            for (list.items) |a| alloc.free(a);
            list.deinit(alloc);
        }
        while (it.next()) |arg| {
            const owned = try alloc.dupeZ(u8, arg);
            errdefer alloc.free(owned);
            try list.append(alloc, owned);
        }
        return try list.toOwnedSlice(alloc);
    } else {
        return std.process.argsAlloc(alloc);
    }
}

/// Free args allocated by argsAlloc.
pub fn argsFree(alloc: std.mem.Allocator, args: Args) void {
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
        // `.expand_arg0 = .expand` restores PATH lookup for a bare `argv[0]`
        // (e.g. "spirv-val"). On 0.15 the POSIX exec path searched PATH even with
        // no_expand; 0.16's new spawn takes argv[0] literally unless told to
        // expand, so without this every bare-name oracle spawn returns
        // FileNotFound and callers silently skip. COMPAT(0.15).
        const result = try std.process.run(alloc, io, .{ .argv = argv, .expand_arg0 = .expand });
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

/// Read an environment variable, caller-owned, or null if unset or unreadable.
/// Zig 0.16 removed std.process.getEnvVarOwned (env access moved behind std.Io),
/// so this centralizes the split and degrades to null on 0.16, where callers
/// fall back to a PATH lookup. Selected by capability, not version number.
/// COMPAT(0.15): simplify when the floor moves to 0.16.
pub fn getEnvVarOwned(alloc: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (comptime @hasDecl(std.process, "getEnvVarOwned")) {
        return std.process.getEnvVarOwned(alloc, name) catch null;
    } else {
        return null;
    }
}

/// Wall-clock time in nanoseconds, hiding the 0.15/0.16 split. Zig 0.16 removed
/// the top-level std.time.nanoTimestamp (timing moved behind std.Io's clock
/// vtable), so on 0.16 this constructs a minimal Io and reads the real clock.
/// Dev bench/timing tools use this for elapsed-time diffs; it is not on a hot
/// path in the library or CLI. COMPAT(0.15): drop the shim when the floor is 0.16.
pub fn nanoTimestamp() i128 {
    if (is_0_16) {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const ts = std.Io.Timestamp.now(threaded.io(), .real);
        return @as(i128, ts.nanoseconds);
    } else {
        return std.time.nanoTimestamp();
    }
}

/// Monotonic-ish elapsed timer mirroring the subset of std.time.Timer that the
/// dev bench tools use (start / read / lap / reset), hiding the 0.16 removal of
/// std.time.Timer and std.time.Instant (timing moved behind std.Io). Backed by
/// nanoTimestamp; `start` cannot fail here (the std API returned an error union),
/// so callers drop the `try`/`catch`. COMPAT(0.15): revisit when the floor is 0.16.
pub const Timer = struct {
    start_ns: i128,

    pub fn start() Timer {
        return .{ .start_ns = nanoTimestamp() };
    }

    /// Nanoseconds elapsed since start (or the last reset).
    pub fn read(self: Timer) u64 {
        const d = nanoTimestamp() - self.start_ns;
        return if (d < 0) 0 else @intCast(d);
    }

    pub fn reset(self: *Timer) void {
        self.start_ns = nanoTimestamp();
    }

    /// Nanoseconds since the last lap/start, and restart the interval.
    pub fn lap(self: *Timer) u64 {
        const now = nanoTimestamp();
        const d = now - self.start_ns;
        self.start_ns = now;
        return if (d < 0) 0 else @intCast(d);
    }
};

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
    if (getEnvVarOwned(allocator, "VULKAN_SDK")) |sdk| {
        defer allocator.free(sdk);
        // Treat a set-but-empty value as unset so we fall back to PATH rather
        // than building a bogus relative "Bin/<tool>" path.
        if (sdk.len == 0) return exe;
        defer allocator.free(exe);
        return try std.fs.path.join(allocator, &.{ sdk, "Bin", exe });
    }
    // Unset or unreadable: fall back to PATH lookup by bare name.
    return exe;
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

// ---- Tests ----

test "resolveVulkanTool falls back to bare tool name without VULKAN_SDK" {
    // With VULKAN_SDK unset (or set-but-empty), and on 0.16 where env access is
    // unavailable without an Io context, resolution degrades to the bare name.
    const alloc = std.testing.allocator;
    const got = try resolveVulkanTool(alloc, "spirv-val");
    defer alloc.free(got);
    const expected = if (builtin.os.tag == .windows) "spirv-val.exe" else "spirv-val";
    try std.testing.expectEqualStrings(expected, got);
}

test "absolute file helpers round-trip bytes under the temp dir" {
    const alloc = std.testing.allocator;
    const rand = randomInt(u64);
    const name = try std.fmt.allocPrint(alloc, ".zioshade-compat-test-{x}.bin", .{rand});
    defer alloc.free(name);
    const path = try tempFilePath(alloc, name);
    defer alloc.free(path);

    const payload = "zioshade compat round-trip\x00\x01\x02\xff";
    try writeFileAbsolute(alloc, path, payload);
    defer deleteFileAbsolute(alloc, path) catch {};

    const got = try readFileAbsolute(alloc, path, 1 << 20);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(payload, got);
}

test "tempFilePath yields an absolute path with no doubled separator" {
    const alloc = std.testing.allocator;
    const dir = try tempDir(alloc);
    defer alloc.free(dir);
    // A trailing separator must have been stripped from the temp dir.
    const seps = if (builtin.os.tag == .windows) "\\/" else "/";
    try std.testing.expect(dir.len == 0 or std.mem.indexOfScalar(u8, seps, dir[dir.len - 1]) == null);

    const path = try tempFilePath(alloc, "zioshade-probe.tmp");
    defer alloc.free(path);
    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expect(std.mem.endsWith(u8, path, "zioshade-probe.tmp"));
    // The join must not have produced an empty component (doubled separator).
    try std.testing.expect(std.mem.indexOf(u8, path, "//") == null);
}

test "randomInt advances the PRNG within a process" {
    // Two draws in the same process must differ (the PRNG advances), otherwise
    // callers naming temp files would collide with themselves.
    const a = randomInt(u64);
    const b = randomInt(u64);
    try std.testing.expect(a != b);
}

//! Compatibility layer for Zig 0.15.2 and 0.16.0.
//!
//! Zig 0.16 removed:
//!   - ArrayList.writer(alloc) — use listWriter() below
//!   - std.io.fixedBufferStream() — use StackBufWriter below
//!
//! All APIs work on both 0.15.2 and 0.16.0.

const std = @import("std");

// ---- List writer (replaces ArrayList.writer) ----

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

/// Create a writer for an ArrayList(u8) that works on both Zig versions.
/// Usage: const w = compat.listWriter(&output, alloc);
/// Then: try w.print("fmt", .{args}); try w.writeAll("str");
pub fn listWriter(list: *std.ArrayList(u8), alloc: std.mem.Allocator) ListWriterPtr(u8) {
    return .{ .list = list, .alloc = alloc };
}

// ---- Stack buffer writer (replaces std.io.fixedBufferStream) ----

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

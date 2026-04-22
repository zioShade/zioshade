const std = @import("std");

pub const Diagnostic = struct {
    kind: Kind,
    line: u32,
    column: u32,
    message: []const u8,
    path: []const u8 = "",

    pub const Kind = enum { @"error", warning, note };

    pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.path.len > 0) {
            try writer.print("{s}:{d}:{d}: ", .{ self.path, self.line, self.column });
        } else {
            try writer.print("{d}:{d}: ", .{ self.line, self.column });
        }
        switch (self.kind) {
            .@"error" => try writer.writeAll("error: "),
            .warning => try writer.writeAll("warning: "),
            .note => try writer.writeAll("note: "),
        }
        try writer.writeAll(self.message);
    }
};

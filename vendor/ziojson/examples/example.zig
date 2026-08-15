const std = @import("std");
const ziojson = @import("ziojson");

pub fn main() !void {
    const json = "{\"name\": \"Alice\", \"age\": 30}";

    var tokens: [64]ziojson.Token = undefined;
    const count = try ziojson.tokenize(json, &tokens);
    std.debug.print("tokens: {d}, first is {s}\n", .{ count, @tagName(tokens[0].type) });

    std.debug.print("name: {s}\n", .{ziojson.findKey(json, "name").?});
    std.debug.print("age: {s}\n", .{ziojson.findKey(json, "age").?});
    std.debug.print("brackets balance: {}\n", .{ziojson.isValid(json)});

    // Build JSON with the writer.
    var buf: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    var jw = ziojson.Writer.init(&out);
    try jw.beginObject();
    try jw.field("name");
    try jw.writeString("Alice");
    try jw.field("age");
    try jw.writeInt(30);
    try jw.endObject();
    std.debug.print("built: {s}\n", .{buf[0..out.end]});
}

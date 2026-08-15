//! Negative fixtures for the per-opcode minimum word count check.
//!
//! Each `truncated_*.spv` is a real GraphicsFuzz module with exactly one
//! instruction rewritten to be one word shorter than the SPIR-V spec minimum
//! for its opcode (the dropped operand words are deleted so the instruction
//! stream stays aligned). Before `common.minWordCount` existed, every one of
//! these crashed the backends with an out-of-bounds index panic, because the
//! emit arms read `inst.words[2]`, `inst.words[3]` and `inst.words[4..]`
//! without a length guard.
//!
//! Regenerate the fixtures with `python3 tools/gen_truncated_fixtures.py`.

const std = @import("std");
const zioshade = @import("zioshade");

const alloc = std.testing.allocator;

const truncated_accesschain = @embedFile("truncated_accesschain_spv");
const truncated_vectorshuffle = @embedFile("truncated_vectorshuffle_spv");
const truncated_functioncall = @embedFile("truncated_functioncall_spv");

/// Untruncated source module of `truncated_vectorshuffle.spv`. Positive control:
/// the check must reject the truncation, not the module.
const valid_module = @embedFile("valid_module_spv");

fn toWords(bytes: []const u8) ![]u32 {
    const words = try alloc.alloc(u32, bytes.len / 4);
    @memcpy(std.mem.sliceAsBytes(words), bytes[0 .. words.len * 4]);
    return words;
}

/// Every backend must reject the module with a loud error rather than panic.
fn expectTruncatedOnAllBackends(bytes: []const u8) !void {
    const words = try toWords(bytes);
    defer alloc.free(words);

    try std.testing.expectError(error.InvalidSpirvTruncated, zioshade.spirvToGLSL(alloc, words, .{}));
    try std.testing.expectError(error.InvalidSpirvTruncated, zioshade.spirvToHLSL(alloc, words, .{}));
    try std.testing.expectError(error.InvalidSpirvTruncated, zioshade.spirvToMSL(alloc, words, .{}));
    try std.testing.expectError(error.InvalidSpirvTruncated, zioshade.spirvToWGSL(alloc, words, .{}));
}

test "truncated OpAccessChain is rejected by every backend" {
    try expectTruncatedOnAllBackends(truncated_accesschain);
}

test "truncated OpVectorShuffle is rejected by every backend" {
    try expectTruncatedOnAllBackends(truncated_vectorshuffle);
}

test "truncated OpFunctionCall is rejected by every backend" {
    try expectTruncatedOnAllBackends(truncated_functioncall);
}

test "positive control: the untruncated module is not rejected as truncated" {
    const words = try toWords(valid_module);
    defer alloc.free(words);

    // The control exists to show the truncation check rejects the TRUNCATION, not the
    // module. This module is graphicsfuzz_001 (the truncated_vectorshuffle fixture is
    // generated from it), whose loop condition is a short-circuit `&&` chain. The GLSL
    // backend now LOWERS that chain correctly (#shortcircuit-loop-cond); before that it
    // refused (UnsupportedPhiAlias via the unclaimed-phi net, and before #579 it
    // miscompiled by dropping the second operand). Accept a clean compile or either
    // documented semantic refusal, and fail on anything else, InvalidSpirvTruncated
    // above all.
    if (zioshade.spirvToGLSL(alloc, words, .{})) |out| {
        defer alloc.free(out);
        try std.testing.expect(out.len > 0);
    } else |err| {
        try std.testing.expect(err != error.InvalidSpirvTruncated);
        try std.testing.expect(err == error.UnsupportedPhiAlias or err == error.UnsupportedShortCircuitLoopCond);
    }
}

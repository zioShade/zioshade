// SPDX-License-Identifier: MIT OR Apache-2.0
// Stub optimization passes — identity functions that skip all optimization.
// Used by the shader-compile tool to avoid compiling 10K lines of real passes.
const std = @import("std");

pub fn deadCodeElim(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn mergeAccessChains(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn deadLoopElim(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn retargetEmptyBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn mergeBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn mergeNonEmptyBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn foldSelect(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn dedupStructTypes(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn dedupArrayTypes(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn dedupPointerTypes(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimSelfRefArithmetic(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn eliminateDoubleNegate(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn foldNegateIntoAddSub(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn redundantStoreElim(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn algebraicSimpl(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimUnreachableCalls(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn inlineTrivialFuncs(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn moveVarToEntry(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimUninitVars(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn fixEarlyAccessVars(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimRedundantLoads(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn foldCompositeExtract(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn cseWithinBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn constStoreForward(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn constFold(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn scatterStoreToComposite(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn storeForwardExtract(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimTrivialEntryPoint(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimIdentityShuffle(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn foldShuffleFromComposite(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimDeadVoidCalls(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimDeadVarStores(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn copyMemoryOpt(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimIdentityStores(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimDeadFunctions(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn hoistInvariantACs(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn branchMergePhi(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimUnusedImports(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimUnusedGlobals(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn stripDeadDebugInfo(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn dedupFunctionTypes(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn fixTypeOrdering(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn foldConstBranches(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn elimUnreachableBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn foldConstCompositeExtract(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}
pub fn simplifyTrivialPhi(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    return alloc.dupe(u32, words);
}

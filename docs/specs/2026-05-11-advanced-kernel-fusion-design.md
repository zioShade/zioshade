# Advanced Kernel Fusion Design

## Scope

Three features for `kernel_fusion.zig`, in implementation order:

1. **Transitive fusion** — Chain A→B→C into a single kernel
2. **Cost model** — Rank fusion candidates by expected benefit
3. **Reduction fusion** — Detect and fuse reduction patterns (e.g., sum, max)

Out of scope (future work):
- Producer-Consumer fusion via shared memory (needs workgroup support)
- Multi-module SPIR-V linking (already partially done via `linkSPIRVModules`)

---

## 1. Transitive Fusion

### Problem
`fuseKernels` currently fuses exactly one pair per call. Given kernels A→B→C where A writes to buffer X, B reads X and writes Y, C reads Y — only A+B or B+C gets fused, not all three.

### Design
Change `fuseKernels` to loop: fuse the best candidate, re-analyze the result, repeat until no more candidates exist.

```
fuseKernels(words, options):
  current = words
  loop:
    entries = findEntryPoints(current)
    candidates = findFusionCandidates(entries, options)
    if candidates is empty: break
    ranked = rankCandidates(candidates, entries)  // cost model
    current = fusePair(current, entries, ranked[0])
  return current
```

Key considerations:
- Each iteration re-analyzes the fused module from scratch. This is O(n²) in the number of kernels but kernel counts are small (typically <10).
- After each fusion, the combined instruction count must still respect `max_fused_size`.
- Stop when no candidates remain or the iteration count hits a limit (guard: max 16 iterations).

### Changes to `kernel_fusion.zig`

**`fuseKernels`** — Replace single-pair logic with iterative loop:
```zig
pub fn fuseKernels(alloc, words, options) ![]const u32 {
    var current = words;
    var needs_free = false;
    var iterations: u32 = 0;
    const max_iterations = 16;
    
    while (iterations < max_iterations) : (iterations += 1) {
        // re-analyze
        var entries = try findEntryPoints(current, ...);
        defer cleanup;
        
        var candidates = try findFusionCandidates(entries, options, alloc);
        defer cleanup;
        
        if (candidates.len == 0) break;
        
        // rank by cost model
        rankCandidates(candidates, entries);
        
        const fused = try fusePair(current, entries, candidates[0], alloc);
        if (needs_free) alloc.free(current);
        current = fused;
        needs_free = true;
    }
    
    // compact IDs on final result
    return compactIds(alloc, current);
}
```

No changes to `fusePair`, `findFusionCandidates`, or `findEntryPoints`.

---

## 2. Cost Model

### Problem
`findFusionCandidates` returns candidates in the order they're found (nested loop). The first candidate isn't necessarily the best.

### Design
Add a `FusionScore` and rank candidates before picking the best one.

Scoring heuristic:
- **shared_buffer_count** (higher = better): more shared buffers = more memory traffic eliminated
- **combined_instruction_count** (lower = better): smaller fused kernels = less register pressure
- **is_chain_start** (bonus): prefer producers that are themselves results of prior fusion

```zig
const FusionScore = struct {
    shared_buffers: u32,
    combined_size: u32,
    
    fn rank(self) i32 {
        // More shared buffers is better, smaller combined size is better
        return @as(i32, @intCast(self.shared_buffers * 100)) - @as(i32, @intCast(self.combined_size));
    }
};
```

### Changes

**`findFusionCandidates`** — Add score field to `FusionCandidate`:
```zig
const FusionCandidate = struct {
    producer_idx: u32,
    consumer_idx: u32,
    shared_buffers: std.ArrayListUnmanaged(u32),
    score: i32 = 0,  // NEW
};
```

Compute score during candidate discovery. After collecting all candidates, sort by score descending.

---

## 3. Reduction Fusion

### Problem
`fuse_into_reduction` is a flag in `FusionOptions` but is never checked. Reduction patterns (e.g., sum across workgroup) need special detection because they have different fusion constraints than elementwise kernels.

### What is a reduction kernel?
A reduction kernel uses workgroup shared memory + barriers to compute an aggregate (sum, min, max, product) across a workgroup. Example pattern:

```glsl
shared float shared_buf[64];
shared_buf[gl_LocalInvocationID.x] = input[gl_GlobalInvocationID.x];
barrier();
// reduction loop
for (uint stride = 32; stride > 0; stride >>= 1) {
    if (gl_LocalInvocationID.x < stride)
        shared_buf[gl_LocalInvocationID.x] += shared_buf[gl_LocalInvocationID.x + stride];
    barrier();
}
if (gl_LocalInvocationID.x == 0) output[gl_WorkGroupID.x] = shared_buf[0];
```

### Detection heuristic

A kernel is a reduction if:
1. Uses `Workgroup` storage class (shared memory)
2. Has `OpControlBarrier` instructions
3. Has a loop with a halving stride pattern (hard to detect at SPIR-V binary level)
4. Exactly one output buffer write after the barrier (the reduced result)

For SPIR-V binary-level detection, we use a simpler heuristic:
- Uses workgroup memory + barriers
- Has `OpAtomic*` operations (common in reduction patterns)
- OR has a single store after the last barrier (reduction output)

### Fusion rules for elementwise → reduction

An elementwise producer can be fused into a reduction consumer if:
1. The elementwise kernel writes to a buffer that the reduction reads
2. The elementwise kernel has no barriers/atomics/workgroup (already checked)
3. The reduction kernel's shared memory loads from the shared buffer can be replaced with the producer's computed values
4. The combined size is within limits

**Important constraint**: We do NOT fuse INTO the reduction body itself. Instead, we prepend the elementwise kernel's body before the reduction's barrier+shared-memory section. The producer's output goes directly into the shared memory buffer instead of going through global memory.

This is actually complex because it requires remapping the reduction's `OpLoad` from the input buffer to the producer's computed values (same as elementwise fusion), but the reduction's shared memory operations must be preserved.

### Design

**New function `detectReductionPattern`**:
```zig
const ReductionInfo = struct {
    is_reduction: bool,
    /// The buffer variable that contains the reduction input.
    input_buffer: ?u32,
    /// The buffer variable that contains the reduction output.
    output_buffer: ?u32,
};

fn detectReductionPattern(entry: *const EntryPoint, words: []const u32, bound: u32) ReductionInfo;
```

**Updated `findFusionCandidates`**: When `fuse_into_reduction` is true, also consider candidates where the consumer is a reduction kernel (even though it has workgroup/barriers). Skip candidates where the producer is a reduction.

**Updated `fusePair`**: When fusing elementwise → reduction, the consumer's body is preserved as-is. Only the loads from the shared input buffer are replaced with producer values. The stores to shared memory are kept.

### Changes

1. Add `ReductionInfo` detection
2. Add `reduction_info` field to `EntryPoint`
3. Update `findFusionCandidates` to consider reduction consumers
4. Update `fusePair` to handle reduction consumers (keep barriers/shared memory, only replace input loads)

---

## Tests

### Transitive fusion
- Three kernels A→B→C sharing buffers. Verify result has 1 entry point.
- Verify intermediate buffers (shared between A→B and B→C) are eliminated.

### Cost model
- Three kernels where two pairs are candidates. Verify the better-scoring pair is fused first.
- Verify cost model prefers more shared buffers.

### Reduction fusion
- Elementwise kernel → reduction kernel. Verify fusion succeeds.
- Reduction → elementwise should NOT fuse (producer can't be reduction).
- Two reduction kernels should NOT fuse.

---

## Implementation Order

1. Cost model (small, independent, needed by transitive fusion)
2. Transitive fusion (builds on cost model)
3. Reduction fusion (most complex, new detection logic)

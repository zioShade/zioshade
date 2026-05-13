#!/usr/bin/env python3
"""Streamline codegen.zig optimization pipeline — remove redundant iterations."""
import re, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))

with open('src/codegen.zig', 'r') as f:
    text = f.read()

# Find the pipeline boundaries
start_marker = 'const raw = try cg.words.toOwnedSlice(alloc);'
end_marker = 'return final_compact5;'

start_idx = text.index(start_marker)
end_idx = text.index(end_marker) + len(end_marker)

# The new streamlined pipeline
new_pipeline = """
    // === Streamlined optimization pipeline ===
    // Single pass of each optimization category. Removes repeated iterations
    // that provided diminishing returns for compute shaders.

    // Early cleanup: merge access chains + DCE
    const merged = opt.mergeAccessChains(alloc, raw) catch raw;
    if (merged.ptr != raw.ptr) alloc.free(raw);
    const dce = opt.deadCodeElim(alloc, merged) catch return merged;
    if (dce.ptr != merged.ptr) alloc.free(merged);
    const no_wrapper = opt.elimTrivialEntryPoint(alloc, dce) catch return dce;
    if (no_wrapper.ptr != dce.ptr) alloc.free(dce);
    const loop_elim = opt.deadLoopElim(alloc, no_wrapper) catch return no_wrapper;
    if (loop_elim.ptr != no_wrapper.ptr) alloc.free(no_wrapper);
    const no_unreachable = opt.elimUnreachableCalls(alloc, loop_elim) catch loop_elim;
    if (no_unreachable.ptr != loop_elim.ptr) alloc.free(loop_elim);

    // Inlining (single pass with fixup)
    var inlined = opt.inlineTrivialFuncs(alloc, no_unreachable) catch return no_unreachable;
    if (inlined.ptr != no_unreachable.ptr) alloc.free(no_unreachable);
    {
        const var_fixed = opt.moveVarToEntry(alloc, inlined) catch inlined;
        if (var_fixed.ptr != inlined.ptr) alloc.free(inlined);
        const dce2 = opt.deadCodeElim(alloc, var_fixed) catch var_fixed;
        if (dce2.ptr != var_fixed.ptr) alloc.free(var_fixed);
        inlined = opt.compactIds(alloc, dce2) catch dce2;
        if (inlined.ptr != dce2.ptr) alloc.free(dce2);
    }

    // Dead function removal
    const no_dead_calls = opt.elimDeadVoidCalls(alloc, inlined) catch return inlined;
    if (no_dead_calls.ptr != inlined.ptr) alloc.free(inlined);
    const no_dead_funcs = opt.elimDeadFunctions(alloc, no_dead_calls) catch return no_dead_calls;
    if (no_dead_funcs.ptr != no_dead_calls.ptr) alloc.free(no_dead_calls);

    // Loop counter to Phi + branch merge Phi
    const phi = loop_phi.loopCounterToPhi(alloc, no_dead_funcs) catch return no_dead_funcs;
    if (phi.ptr != no_dead_funcs.ptr) alloc.free(no_dead_funcs);
    const bphi = opt.branchMergePhi(alloc, phi) catch return phi;
    if (bphi.ptr != phi.ptr) alloc.free(phi);
    const simpl_phi = opt.simplifyTrivialPhi(alloc, bphi) catch bphi;
    if (simpl_phi.ptr != bphi.ptr) alloc.free(bphi);

    // Store forwarding + block merging
    const rse = opt.redundantStoreElim(alloc, simpl_phi) catch return simpl_phi;
    if (rse.ptr != simpl_phi.ptr) alloc.free(simpl_phi);
    const blk1 = opt.mergeBlocks(alloc, rse) catch return rse;
    if (blk1.ptr != rse.ptr) alloc.free(rse);
    const blk2 = opt.mergeNonEmptyBlocks(alloc, blk1) catch return blk1;
    if (blk2.ptr != blk1.ptr) alloc.free(blk1);

    // Hoist invariant access chains
    const hoisted = opt.hoistInvariantACs(alloc, blk2) catch return blk2;
    if (hoisted.ptr != blk2.ptr) alloc.free(blk2);
    const hoisted_dce = opt.deadCodeElim(alloc, hoisted) catch return hoisted;
    if (hoisted_dce.ptr != hoisted.ptr) alloc.free(hoisted);

    // Multi-block inlining
    const mb_inlined = inline_mb.inlineMultiBlock(alloc, hoisted_dce) catch return hoisted_dce;
    if (mb_inlined.ptr != hoisted_dce.ptr) alloc.free(hoisted_dce);
    const mb_merged = opt.mergeBlocks(alloc, mb_inlined) catch mb_inlined;
    if (mb_merged.ptr != mb_inlined.ptr) alloc.free(mb_inlined);
    const mb_merged2 = opt.mergeNonEmptyBlocks(alloc, mb_merged) catch return mb_merged;
    if (mb_merged2.ptr != mb_merged.ptr) alloc.free(mb_merged);
    const mb_dce = opt.deadCodeElim(alloc, mb_merged2) catch return mb_merged2;
    if (mb_dce.ptr != mb_merged2.ptr) alloc.free(mb_merged2);

    // Type dedup
    const deduped = opt.dedupStructTypes(alloc, mb_dce) catch return mb_dce;
    if (deduped.ptr != mb_dce.ptr) alloc.free(mb_dce);

    // Arithmetic simplification chain
    const neg1 = opt.elimSelfRefArithmetic(alloc, deduped) catch return deduped;
    if (neg1.ptr != deduped.ptr) alloc.free(deduped);
    const neg2 = opt.eliminateDoubleNegate(alloc, neg1) catch return neg1;
    if (neg2.ptr != neg1.ptr) alloc.free(neg1);
    const neg3 = opt.foldNegateIntoAddSub(alloc, neg2) catch return neg2;
    if (neg3.ptr != neg2.ptr) alloc.free(neg2);
    const algebrad = opt.algebraicSimpl(alloc, neg3) catch return neg3;
    if (algebrad.ptr != neg3.ptr) alloc.free(neg3);
    const cf = opt.constFold(alloc, algebrad) catch return algebrad;
    if (cf.ptr != algebrad.ptr) alloc.free(algebrad);
    const folded = opt.foldSelect(alloc, cf) catch return cf;
    if (folded.ptr != cf.ptr) alloc.free(cf);

    // Control flow optimization
    const folded_br = opt.foldConstBranches(alloc, folded) catch folded;
    if (folded_br.ptr != folded.ptr) alloc.free(folded);
    const elim_blks = opt.elimUnreachableBlocks(alloc, folded_br) catch folded_br;
    if (elim_blks.ptr != folded_br.ptr) alloc.free(folded_br);
    const phi2 = opt.simplifyTrivialPhi(alloc, elim_blks) catch elim_blks;
    if (phi2.ptr != elim_blks.ptr) alloc.free(elim_blks);
    const compacted = opt.compactIds(alloc, phi2) catch return phi2;
    if (compacted.ptr != phi2.ptr) alloc.free(phi2);

    // Memory optimization
    const no_rle = opt.elimRedundantLoads(alloc, compacted) catch return compacted;
    if (no_rle.ptr != compacted.ptr) alloc.free(compacted);
    const no_dup = opt.cseWithinBlocks(alloc, no_rle) catch return no_rle;
    if (no_dup.ptr != no_rle.ptr) alloc.free(no_rle);

    // Composite optimization
    const cce = opt.foldConstCompositeExtract(alloc, no_dup) catch no_dup;
    if (cce.ptr != no_dup.ptr) alloc.free(no_dup);
    const ce = opt.foldCompositeExtract(alloc, cce) catch return cce;
    if (ce.ptr != cce.ptr) alloc.free(cce);
    const sh = opt.foldShuffleFromComposite(alloc, ce) catch ce;
    if (sh.ptr != ce.ptr) alloc.free(ce);
    const ecs = fold_ec.foldExtractConstructToShuffle(alloc, sh) catch sh;
    if (ecs.ptr != sh.ptr) alloc.free(sh);
    const no_id_sh = opt.elimIdentityShuffle(alloc, ecs) catch return ecs;
    if (no_id_sh.ptr != ecs.ptr) alloc.free(ecs);

    // Variable optimization
    const no_uninit = opt.elimUninitVars(alloc, no_id_sh) catch return no_id_sh;
    if (no_uninit.ptr != no_id_sh.ptr) alloc.free(no_id_sh);
    const const_fwd = opt.constStoreForward(alloc, no_uninit) catch return no_uninit;
    if (const_fwd.ptr != no_uninit.ptr) alloc.free(no_uninit);
    const fixed_early = opt.fixEarlyAccessVars(alloc, const_fwd) catch const_fwd;
    if (fixed_early.ptr != const_fwd.ptr) alloc.free(const_fwd);

    // Store-to-composite + store-forward
    const scattered = opt.scatterStoreToComposite(alloc, fixed_early) catch return fixed_early;
    if (scattered.ptr != fixed_early.ptr) alloc.free(fixed_early);
    const forwarded = opt.storeForwardExtract(alloc, scattered) catch return scattered;
    if (forwarded.ptr != scattered.ptr) alloc.free(scattered);

    // Final cleanup
    const no_dead_stores = opt.elimDeadVarStores(alloc, forwarded) catch forwarded;
    if (no_dead_stores.ptr != forwarded.ptr) alloc.free(forwarded);
    const final_dce = opt.deadCodeElim(alloc, no_dead_stores) catch return no_dead_stores;
    if (final_dce.ptr != no_dead_stores.ptr) alloc.free(no_dead_stores);
    const retargeted = opt.retargetEmptyBlocks(alloc, final_dce) catch return final_dce;
    if (retargeted.ptr != final_dce.ptr) alloc.free(final_dce);
    const final_cse = opt.cseWithinBlocks(alloc, retargeted) catch return retargeted;
    if (final_cse.ptr != retargeted.ptr) alloc.free(retargeted);
    const final_dce2 = opt.deadCodeElim(alloc, final_cse) catch return final_cse;
    if (final_dce2.ptr != final_cse.ptr) alloc.free(final_cse);
    const no_id_stores = opt.elimIdentityStores(alloc, final_dce2) catch final_dce2;
    if (no_id_stores.ptr != final_dce2.ptr) alloc.free(final_dce2);
    const copy_mem = opt.copyMemoryOpt(alloc, no_id_stores) catch return no_id_stores;
    if (copy_mem.ptr != no_id_stores.ptr) alloc.free(no_id_stores);
    const final_dce3 = opt.deadCodeElim(alloc, copy_mem) catch return copy_mem;
    if (final_dce3.ptr != copy_mem.ptr) alloc.free(copy_mem);
    const compacted2 = opt.compactIds(alloc, final_dce3) catch return final_dce3;
    if (compacted2.ptr != final_dce3.ptr) alloc.free(final_dce3);

    // Import + global cleanup (single pass)
    const no_imports = opt.elimUnusedImports(alloc, compacted2) catch return compacted2;
    if (no_imports.ptr != compacted2.ptr) alloc.free(compacted2);
    const no_imports_dce = opt.deadCodeElim(alloc, no_imports) catch return no_imports;
    if (no_imports_dce.ptr != no_imports.ptr) alloc.free(no_imports);
    const compacted3 = opt.compactIds(alloc, no_imports_dce) catch return no_imports_dce;
    if (compacted3.ptr != no_imports_dce.ptr) alloc.free(no_imports_dce);
    const gu = opt.elimUnusedGlobals(alloc, compacted3) catch return compacted3;
    if (gu.ptr != compacted3.ptr) alloc.free(compacted3);
    const gu_dce = opt.deadCodeElim(alloc, gu) catch gu;
    if (gu_dce.ptr != gu.ptr) alloc.free(gu);
    const gu_strip = opt.stripDeadDebugInfo(alloc, gu_dce) catch gu_dce;
    if (gu_strip.ptr != gu_dce.ptr) alloc.free(gu_dce);
    const gu_dce2 = opt.deadCodeElim(alloc, gu_strip) catch gu_strip;
    if (gu_dce2.ptr != gu_strip.ptr) alloc.free(gu_strip);
    const gu_compact = opt.compactIds(alloc, gu_dce2) catch return gu_dce2;
    if (gu_compact.ptr != gu_dce2.ptr) alloc.free(gu_dce2);

    // Final type dedup
    const deduped_arr = opt.dedupArrayTypes(alloc, gu_compact) catch return gu_compact;
    if (deduped_arr.ptr != gu_compact.ptr) alloc.free(gu_compact);
    const deduped_struct = opt.dedupStructTypes(alloc, deduped_arr) catch return deduped_arr;
    if (deduped_struct.ptr != deduped_arr.ptr) alloc.free(deduped_arr);
    const deduped_ptr = opt.dedupPointerTypes(alloc, deduped_struct) catch return deduped_struct;
    if (deduped_ptr.ptr != deduped_struct.ptr) alloc.free(deduped_struct);
    const deduped_func = opt.dedupFunctionTypes(alloc, deduped_ptr) catch deduped_ptr;
    if (deduped_func.ptr != deduped_ptr.ptr) alloc.free(deduped_ptr);
    const tail_dce = opt.deadCodeElim(alloc, deduped_func) catch return deduped_func;
    if (tail_dce.ptr != deduped_func.ptr) alloc.free(deduped_func);
    const result = opt.compactIds(alloc, tail_dce) catch return tail_dce;
    if (result.ptr != tail_dce.ptr) alloc.free(tail_dce);
    return result;
"""

# Fix: reconstruct properly
before_pipeline = text[:start_idx + len(start_marker)]
after_pipeline = text[end_idx:]
new_text = before_pipeline + new_pipeline + after_pipeline

# Stats
old_opt_calls = len(re.findall(r'opt\.\w+\(', text[start_idx:end_idx]))
new_opt_calls = len(re.findall(r'opt\.\w+\(', new_pipeline))
old_lines = text[start_idx:end_idx].count('\n')
new_lines = new_pipeline.count('\n')

print(f'Pipeline: {old_lines} lines, {old_opt_calls} opt calls -> {new_lines} lines, {new_opt_calls} opt calls')

with open('src/codegen.zig', 'w') as f:
    f.write(new_text)
print('Written to src/codegen.zig')

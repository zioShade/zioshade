# GOAL — zioshade autonomous correctness run (2026-07-28)

Host: Claude Code. Mode: autonomous-panel. Plain subagents for panels.

## Goal
Reduce zioshade's known-deferred compile-INVALID backlog (the silent-wrong-adjacent
surface), prioritizing the loop/phi hoist neighborhood. Each bug: root-cause, fix,
verify, commit on a LOCAL feature branch. Push/PR is Tier 2 (escalate, batch).

## Done-criteria (per bug, all must hold)
- Target shader glslang-valid (exit 0) in the affected backend(s).
- Full `zig build test` green (0 fail).
- Relevant corpus gate (glsl/hlsl_glslang_sweep) regression=0.
- prove_opt (MSL render-diff) shows 0 NEW DIFFER if the change touches MSL.
- zig fmt --check clean (0.15.2).
- Committed on a local feature branch (not pushed — escalate).

## Constraints
- No Co-Authored-By, no em dashes (zioshade convention).
- zig 0.15.2 via mise; export DEVELOPER_DIR=/Library/Developer/CommandLineTools.
- Tier 0: investigate/fix/verify/commit-local. Tier 1: panel for real trade-offs.
  Tier 2: push/PR/taste → draft + escalate.
- Branch each fix from main (independent).

## Queue
1. [in progress] false-loop-init (HLSL #491 selection-merge-phi hoist; GLSL equiv?)
2. partial-write-preserve (cross-backend inout partial-write)
3. (reassess) GLSL vertex/compute triage (~29), #76 WGSL loop-in-switch, chaos hunt

## MERGED to main (2026-07-28) — all 5 PRs squash-merged in order
#480 → #482 → #483 → #484 → #481. One conflict (#484 vs #483 in hlsl_tests.zig — both
added a test after #493; resolved by keeping both). Combined main VERIFIED: build clean,
GLSL gate valid=1427/INVALID=0/regression=0, HLSL gate valid=1404/INVALID=0/regression=0
(baselines now empty — all known-deferred INVALIDs fixed + enforced), full zig build test
exit 0. PRE-EXISTING: src/spirv_to_{msl,glsl,hlsl}.zig + tests/loop_phi_tests.zig +
wgsl_packing_bitfield_tests.zig + tests/runner.zig are fmt-dirty at 23da664 ALREADY (CI
fmt gate billing-blocked so latent) — NOT from these PRs (verified: fmt wants none of the
added lines). Separate `zig fmt` normalization recommended when CI re-enabled.

## fmt + common.* dedup (2026-07-28) — MERGED to main (#485, #486, #487); DEDUP COMPLETE
Three follow-up PRs, all verified green (each behavior-preserving: full suite + GLSL 1427/0/0
+ HLSL 1404/0/0 + MSL render-diff byte-identical to baseline via stash+rebuild A/B). MERGED.
- chore/zig-fmt-normalize (bc7ce13): `zig fmt` over src/ + tests/. All pre-existing
  drift normalized; two stale test files (print_isampler, hlsl_loop_test_fragment2)
  used invalid single-backslash multiline strings (dead, not compiled) — modernized to
  \\ so they parse. `zig fmt --check` now exit 0 tree-wide; full zig build test green.
- refactor/common-dedup (93591d9, STACKED on fmt so moved code stays fmt-clean):
  extracted the do-while back-edge cluster (detectDoWhileBackEdge, dwFindRouter,
  inlineDoWhileOperand, tryInlineDoWhileCond, inlineShortCircuitPhi + DwRouter) from
  msl/glsl/hlsl into spirv_cross_common.zig. The freshest triplication (#77, written
  uniformly into all 3). module:anytype + localGetDef; std450_name:anytype threaded
  (msl/glsl pass std450ToMsl/Glsl; hlsl a u32->enum adapter). Net -472 lines.
  VERIFIED behavior-preserving: build exit 0; full zig build test exit 0 (incl #77
  loop-phi exact-ternary all 3 backends); GLSL gate 1427/0/0; HLSL gate 1404/0/0;
  full MSL render-diff IDENTICAL to pre-refactor baseline (1123 MATCH, same 10 chaotic
  DIFFERs, 0 new — confirmed by stashing dedup, rebuilding, re-running --dir).
  Merge order: fmt FIRST (foundational formatting), then dedup rebases clean.
- REMAINING (genuinely backend-specific, NOT worth extracting — verified divergent):
  emitStd450 (Metal-only vector lowering #488); access/pointer cluster (writeAccessExpr/
  writeResolvePointer/buildAccessExpr — row-major/read_context/deref-syntax divergent;
  resolvePointer was DEAD in glsl/hlsl, dropped); sanitizeName (hlsl keyword-collision
  suffix); resultIdFromOp/collectDecorations/Names/Resources/parseModule/findEntryPoint/
  getDef/constantLiteral (per-backend logic differs); central emitInstruction/emitFunction/
  emitBody not even uniformly triplicated. emitBinOp/emitCall WERE extracted (#487).

## Chaos-DIFFER source inspection + input-attachment fix (2026-07-29) — MERGED (#488)
Source-inspected all 10 MSL render-diff DIFFERs (the render-diff masks structural bugs
behind FP/feature chaos; source-vs-oracle inspection is the discriminator). Result:
9 of 10 CERTIFIED non-bugs (faithful source): ceramic/loop_trackers/nested_func_expr/
switch_in_loop/weierstrass = FP/structurization chaos (op-for-op faithful);
combined-texture-sampler.vk + separate-sampler-texture.vk = binding-renumber (zioshade
keeps GLSL bindings, spirv-cross renumbers); image-query.desktop + partial-write-preserve
= degenerate (no output; both DCE identically). 1 REAL silent-wrong bug found + FIXED:
input-attachment.vk — SubpassData OpImageRead passed the (0,0) coord placeholder through,
so Metal read the top-left pixel for every fragment. Fix: detect SubpassData (Dim 6), emit
read(uint2(_fragCoord.xy)). subpassInputMS now honest-errors (UnsupportedMultisampled-
SubpassInput) — MS needs texture2d_ms + per-sample read (deferred). VERIFIED: render-diff
input-attachment.vk DIFFER(255)->MATCH, DIFFER 10->9, 1123 MATCH unchanged, 0 new DIFFER;
input-attachment-ms skip (honest-error); full suite green; GLSL 1427/0/0; HLSL 1404/0/0;
loop-phi 29/29 (2 new fixtures). The remaining 9 DIFFERs are now CERTIFIED chaotic
(faithful source; not bug-free-suspected).

## HLSL vert/comp INVALID triage (2026-07-29) — 1 FIXED (#489); 3 DEFERRED to DXC (founder)
DXC CANONICAL GATE NOW WIRED (2026-07-29): image `zioshade-dxc`, container `dxc-oracle`
(DXC 1.9, linux/amd64 Docker; `docker start dxc-oracle`), gate `tools/hlsl_validity_sweep.sh`
(emit on host, one batched `docker exec` DXC validate). Smoke-tested ok. No macOS DXC build.
Triaged all 4 KNOWN_INVALID shaders; each is a distinct machinery/structural bug (and
all are COMPILE-INVALID = loud glslang reject, NOT silent-wrong; panel-deferred to DXC):
- read-from-row-major-array.vert: FIXED (#489). emitStructMembers dropped multi-dim UBO
  array dims + missed row_major on array-of-matrix members -> emitted column-major
  silent-wrong. Fix: emit all dims + drill matrix_tid -> non-square row_major now
  honest-errors (UnsupportedRowMajorMatrix). Full validity (swapped-dims) deferred.
- out-block-qualifiers.vert: root-caused precisely (spirv_to_hlsl.zig:3033 collision guard
  DROPS user output blocks whose member names collide with standalone outputs -- this shader's
  block f/g/h/i @0-3 vs loose f/g/h/i @4-7). The routing (3209) only renames the block VAR
  (vout->output), can't prefix MEMBER names, so a colliding block can't flatten without duplicate
  VS_OUTPUT fields -> vout.X stays undeclared -> INVALID. The code comment itself defers this
  ("needs member-name prefixing / spirv-cross-style block reconstruction, a separate follow-up").
  Fix options: (a) block reconstruction (declare struct + static + prefixed VS_OUTPUT members +
  entry copy vout.X->output.<blk>_<m>), ~60-80 lines; (b) member-name override threaded into the
  access-chain emitter. Both substantial. DEFERRED to a dedicated session.
- cfg.comp: zioshade emits empty switch(){}, drops the body -> v17 undeclared. Needs CFG
  structurization for this shape. DEFERRED.
- spec-constant-op-member-array.vk.comp: FIXED (#490, 2026-07-29). 3-layer: codegen looks up the
  spec-const-op by user_name (analyzer already bound it; map was keyed by synthetic id) -> emits
  OpTypeArray; common.arrayLengthValue evaluates OpSpecConstantOp (IAdd/ISub/IMul of operand
  defaults) to a concrete size; HLSL emitters use it (honest-error unresolvable). DXC then rejects
  only on a shader-inherent StructuredBuffer >2048-byte limit (spirv-cross hits it too; not a bug).


## Panel-review campaign (Mitchell Hashimoto + Andrew Kelley lenses) — DONE
All 5 in-flight PRs reviewed (2 reviewers each). Outcomes:
- #480 (#77): fixed ExtInst→std450 resolver (coverage+dedup), defensive phi invariant
  (eval_is_p0==eval_is_p1), stale CLI msg. Pushed (41e8abc).
- #482 (for-loop-init): Mitchell's "doesn't fire" claim DISMISSED (he tested the wrong
  fixture — spirv_cross_shaders vs spirv-cross). Hardened header scan: resultIdFromOp gate,
  Pattern-B-only deferred_hdr guard, scan-start word 1, func_idx bound. Pushed (827e498).
- #483 (false-loop-init): added HLSL regression test + defer-order fix (restore before
  free). Pushed (13b0bd4).
- #484 (partial-write): added HLSL regression test. Pushed (7e3a8b7).
- #481 (gate machinery): GLSL regression-detection machinery + emptied HLSL fragment
  baseline (false-loop-init + partial-write fixed). Pushed (9e0cbd2).
Deferred (LOW/theoretical/refactor, noted): #480 continue-block side-effect honest-error
  guard (Mitchell, theoretical); #483 leak-on-error errdefer (Andrew, pre-existing low);
  cross-backend triplication→common.* (ALL reviewers, LARGE separate refactor).
Merge order: #482 → #483 → #484 → #481 (→ #480 independent).

## Ledger
- (session start) Resumed under autonomous-panel. #77 (PR #480), for-loop-init (PR #482),
  gate machinery (PR #481) already pushed this session (pre-panel). New work stays local
  until batched push escalation.
- false-loop-init HLSL FIXED (d6d4bc3, branch fix/false-loop-init-phi-hoist, LOCAL — push
  pending). Tier 0: ported GLSL's carried-phis hoist (g_carried_phis_h threadlocal +
  body #491 carried-aware). Verified: HLSL glslang-valid, full suite green, fmt clean.
  Merge after #482 (for-loop-init) for a green gate. Draft PR body in this commit msg.

## Branches awaiting push (Tier 2 — escalate batch)
- fix/false-loop-init-phi-hoist (d6d4bc3) — false-loop-init HLSL fix.
- fix/partial-write-preserve (ffc3ff8) — partial-write-preserve HLSL fix.

## Milestone (2026-07-28)
All 3 HLSL fragment known-INVALIDs now fixed across branches: for-loop-init (#482,
pushed), false-loop-init (local d6d4bc3), partial-write-preserve (local ffc3ff8).
Once all merge, HLSL fragment gate = INVALID 0 / regression 0. Each local branch was
verified from main in isolation (suite green, fmt clean); each shows the OTHERS' bugs
as a pre-existing "NEW REGRESSION" on main — they disappear once the set merges.

## Remaining queue (lower-value / larger, reassess after push)
- GLSL vertex/compute triage (~29 unchecked INVALIDs, fragment-only blind spot).
- #76 WGSL loop-in-switch (low-pri, honest-erroring, 0 corpus hits).
- operand-level chaos hunt (optional, tool-building).

## 2026-07-29 session: validity matrix sweep + certified-bug workflow
Item-2 (GLSL vert/comp triage) DONE: vertex 42/0/0/3he, compute 50/0/0/3inc/24he. ZERO
real-bug INVALIDs (the "~29 unchecked" in the justfile comment + this file's old queue was
stale; cleared by the #480-#492 campaign). 3 compute INCONCLUSIVE are source/extension
limits (fp-atomic/reduce_sum float atomicAdd; subgroup_elect needs SPIR-V 1.3) -> NOT bugs.

Full compile-VALIDITY matrix swept (all 4 backends x all stages):
  HLSL: frag 0, vert 0, comp = cfg.comp (1)        [baseline tools/hlsl_glslang_sweep.sh:101]
  GLSL: frag 0, vert 0, comp 0                      [baselines empty]
  MSL:  frag = for-loop-init.frag (1), vert 0, comp 0  [msl_validity_sweep.sh has NO baseline -> real bug]
  WGSL: naga PASS=1999 / REJECT=0 (full corpus)    [clean]
=> exactly 2 certified compile-INVALIDs remain: for-loop-init.frag (MSL) + cfg.comp (HLSL).

for-loop-init.frag MSL = NEW (not #486's output-typing fix). Root cause: no-OpPhi Private-
counter loop; the #237/#loop-continue-deadincr top-of-loop continue-hoist emits
`%27=%25+1` (int v29=v25+1) inside the `if(!_loopfirst)` block but leaves the `%25=OpLoad`
def (int v25=v8) emitted later in the body -> use-before-declaration -> Metal rejects
(MslCompileCheck: "undeclared identifier 'v25'"). MASKED by spirv-opt -O in prove_opt
(lowers to phi/do-while form) -> only the raw msl-metal sweep sees it. #482 fixed the
GLSL/HLSL twin (carried_phis) but MSL was never ported.

cfg.comp HLSL = dominator-scope var (v17) dropped where used (source tests "variable access
propagates up to dominator"). The GOAL.md "empty switch" note was STALE; switch emits cases
fine now. Real failure is a declaration hoist gap in spirv_to_hlsl.zig.

WORKFLOW wf_0b26c564-2d8 RUNNING (background): 2 worktree fix agents (for-loop-init MSL,
cfg.comp HLSL, each + adversarial verify) + operand-level chaos hunt (10 chaos-proof integer
shaders certified across MSL/GLSL/WGSL, DIFFER=certified bug). Synthesize on completion:
review diffs -> apply + re-verify inline -> triage hunt DIFFERs -> commit local.

## 2026-07-29 PR #493 opened (push authorized: "continue autonomously")
Branch fix/certified-invalids pushed; PR #493 opened (3 commits: 1a04b9b cfg.comp OpUndef,
a1a4068 for-loop-init MSL, 41bc62f bitCount MSL). Pending before squash-merge:
  - background: full-corpus prove_opt --dir (0 DIFFER expected; --sweep already 0)
  - background: feature-dev:code-reviewer subagent (mandate-safety + correctness + interaction)
Merge when both clean. Then: reset local main to origin/main, delete branch.
Remaining deferred (low-value, not re-requested): OpFUnordEqual NaN, 8 snorm/unorm HLSL pack
(DXC), #76 WGSL loop-in-switch (0 corpus hits). Validity matrix + operand hunt DONE.

## 2026-07-29 PR #493 MERGED (squash 424e999)
Subagent review: APPROVE (mandate-safe; #for-loop-init port byte-for-byte faithful to GLSL
#482; cannot over/under-fire). prove_opt full corpus: 0 new DIFFER (MATCH 1125, the 9 DIFFERs
are the known pre-existing chaotic baseline). Squash-merged to main; local main synced; branch
+ worktree branches deleted. Merged main verified: zig build test green, MSL valid=1429/INVALID=0,
HLSL compute valid=51/INVALID=0. COMPILE-VALIDITY MANDATE FULLY MET (0 INVALID all backends/stages).

## 2026-07-29 v0.4.0 RELEASED + wintty pin bumped + operand hunt batch 2
- zioshade v0.4.0 tagged + GitHub pre-release (tag c79e4da; build.zig.zon 0.3.0->0.4.0;
  CHANGELOG v0.4.0 block). Release: https://github.com/zioShade/zioshade/releases/tag/v0.4.0
- deblasis/wintty PR #565 squash-merged (windows branch, add6af9a7): zioshade pin
  194fe60(commit) -> v0.4.0 tag; updated build.zig.zon + mirror lockfiles (.zon.json/.nix/.txt/
  flatpak) with correct tarball sha256 in each format. (NOTE: wintty CLAUDE.md has a
  "never create a PR / write a joke-file" trap; user explicitly overrode it for this.)
- Operand hunt BATCH 2 (5 patterns): extinst integer ops (abs/sign/clamp), int/uint/float
  conversions, VectorShuffle, CompositeExtract/Insert, smulExtended. 4 buildable, ALL MATCH
  across GLSL+WGSL (+MSL where renderable). NO new bugs. Cumulative operand hunt: 14 patterns,
  1 real bug (bitCount, fixed) -> operand path thoroughly certified sound across the probed
  opcode classes. Remaining: founder-deferred DXC snorm/unorm pack ops (8, bounded; DXC
  container available), #76 WGSL loop-in-switch (0 hits).

## 2026-07-30 BROAD HUNT (workflows; "trust no single source, look broadly")
Inventory (background): glsl/wgsl FAITHFULNESS on 537 DETERMINISTIC frags (the non-proxy
discriminator that found #69/#70); prove_naga/prove_opt --dir + glsl/wgsl render (full corpus)
for the residual DIFFER sets. Operand-hunt workflow (8 opcode classes, the structural CF-count
FN gap). All via multi-agent workflows per founder directive.

FAITHFULNESS RESULTS: GLSL 374 FAITHFUL / 3 UNFAITHFUL; WGSL 380 FAITHFUL / 2 UNFAITHFUL.
Adversarial source-inspection (read zioshade vs spirv-cross; try to REFUTE as chaos/UB/confound):
- loop-dominator-and-switch-default.frag: NOT_A_BUG (source UB -- f4.x read uninitialized,
  independently confirmed in SPIR-V; the prior #71 diagnosis was correct).
- mandelbrot-loop.frag: REAL_BUG (see #78).
- struct_array_gradient.frag: REAL_BUG (see #79).
- particle_sim.frag: REAL_BUG (see #80).

### #78 (NEW, silent-wrong) GLSL+WGSL drop loop-break on selection-merge-to-loop-merge
mandelbrot-loop.frag: an OpBranchConditional inside an OpSelectionMerge inside a loop body,
targeting the enclosing loop merge (structured BREAK on mandelbrot escape). MSL emits
`iter = v51; break; } continue;`. GLSL emits `iter = v51; } continue;` (NO break); WGSL same.
=> loop never exits on escape, always runs all iters -> silent-wrong. NOT FP chaos (structural).
MSL correct via g_loop_merge_ctx; GLSL/WGSL lack the equivalent. Root-cause agent running.

### #79 (NEW, silent-wrong) GLSL selection-merge phi declared-unassigned
struct_array_gradient.frag: short-circuit && lowered to OpPhi at a selection merge. MSL emits
`v44_phi = v36;` (default store) BEFORE the if. GLSL declares `bool v44_phi;` (NO default store)
=> when v36 is false (short-circuit), v44_phi read UNINITIALIZED at `if(v44_phi)`. Deterministic
shader -> guaranteed wrong. "phi declared-unassigned = silent-wrong" pattern. Root-cause agent
running (also checking HLSL/WGSL for the same gap).

### #80 (NEW, silent-wrong) WGSL pass-by-value drops inout struct writes
particle_sim.frag: OpTypeFunction with _ptr_Function_* params (inout). MSL `thread Particle&`,
GLSL `inout Particle`. WGSL emits `p: Particle` (by value), body mods a local copy `_inout_p`,
returns void => all inout writes lost. Particle never updates across iterations. Root-cause agent
running (checking whether naga accepts `ptr<function,T>` params for the correct lowering).

FIXES: apply after the inventory (render track B) + operand-hunt finish (don't rebuild the main
binary while background jobs use it). Each: root-cause -> minimal fix -> regression fixture ->
verify (faithfulness DIFFER->MATCH + gate regression=0 + zig build test green + fmt clean).
Commit on local feature branches; push = Tier 2 (escalate batch).

### FIX PLANS (root-caused 2026-07-30; apply after workflows finish, no rebuild meanwhile)
#78 GLSL+WGSL loop-break-on-selection-merge:
  GLSL: add g_loop_merge_ctx threadlocal (merge_label only); set in emitWhileLoop (save/restore
  via defer); check in emitBlock .Branch handler -- if target==g_loop_merge_ctx.merge_label emit
  break; (mirrors MSL 7254-7259). WGSL: add `target==loop_merge_label -> break;` arm in emitBlock
  .Branch handler after the continue check (~6803). Only OpBranch needed (conditional-direct
  already covered). spirv-opt -O MASKS it (test with NO -O). No phi-copy needed for mandelbrot
  (no OpPhi at merge). Fixture: break_on_selmerge.frag (if(dot>1){iter=i;break;}).
#79 GLSL selection-merge phi declared-unassigned (GLSL-only; HLSL+WGSL correct):
  Add `if (he)` guard at spirv_to_glsl.zig:3319-3323 (+latent 3830-3336, 4050-4053): when no else
  arm, init phi to skip-path incoming via phiPred1InTrueRegion (mirrors MSL 6310-6320 + GLSL false-
  arm copy 3339). spirv-opt -O does NOT mask. Fixture: struct_array_gradient.src.spv -> tests/fixtures.
#80 WGSL inout-by-value (whole multi-inout + non-void-inout class; single-inout-void works):
  CONSERVATIVE split: keep single-inout-void return-value idiom; route multi-inout + non-void-inout
  through ptr<function,T> params + (*name) deref remap (so OpLoad/OpStore/AccessChain go through the
  pointer w/o hot-path edits) + caller & prefix. Sites: signature 4251-4304, body 4306-4334, caller
  7932-7990. naga-validated ptr<function,T> params + (*p)[0]/&s.b. spirv-opt -O MASKS (inlines fn).
  Regression: wgsl-faithful on inout fixtures (particle_sim, wgsl_inout_chain, struct_param_modify,
  flush_params must stay FAITHFUL); + chaos-proof integer-accumulator fixture.

## 2026-07-30 BROAD HUNT -> FIX CAMPAIGN (in progress)
Hunt (workflows) found ~17 bug classes (~37 bugs). Trust-no-single-source methodology
paid off: non-proxy faithfulness + source inspection + real-compiler oracles (DXC/naga/Metal)
surfaced bugs the render-diff/3-oracle had certified as chaos/AGREE-ALL.

COMMITTED on branch fix/broad-correctness-hunt (from main c79e4da):
- 39ca36b fix(glsl): selection-merge phi init on short-circuit path (#79). Covers
  struct_array_gradient, geology, ray_struct, raytracing, recursive_struct. GLSL gate 0 reg.
- 42ddcae fix(glsl,wgsl): break for side-effecting break-to-loop-merge (#78). Covers
  mandelbrot-loop (+ multi_return2). GLSL gate 0 reg, WGSL naga 0 reg.
- 954dc64 fix(hlsl,wgsl): Fma float lowering (mad not fma -- #469 regression) + compute-only
  barriers (workgroupBarrier/storageBarrier fragment-forbidden).

DELEGATED to worktree fix workflow (wf_e1aa5fa6-6b2, running): 9 classes, each implemented+
verified+committed in its own worktree, then independent re-verify:
  wgsl-inout (#80), wgsl-subpass-coord (#488 port), wgsl-atomic-field, subgroup-operand+builtin,
  image-sample-operands (Dref Lod/ConstOffset), hlsl-matrix-nonsquare, imagefetch-glsl-ms+hlsl-int3,
  ubo-nested-rowmajor, switch-edge-cases.
Worktree agents branch from origin/main (no my 4 commits); merge their patches into the campaign
branch on completion, then final full-suite verify + escalate push (Tier 2).
Resumption: workflow journal at <transcriptDir>/wf_e1aa5fa6-6b2/journal.jsonl; each agent returns
{class, commit_sha, patch_diff, verification, reverify}. Apply PASS patches to fix/broad-correctness-hunt.

## 2026-07-30 FIX CAMPAIGN -> MERGED + VERIFIED GREEN
All 8 worktree fix commits cherry-picked onto fix/broad-correctness-hunt (resolved the
spirv_to_wgsl.zig emitBody signature union: atomic_vars, atomic_fields, early_return,
subpass_fragcoord_name across inout/subpass/atomic; hlsl:2579 overlap auto-merged).
11 commits total on top of v0.4.0 (c79e4da): #79 phi, #78 break, Fma+barrier, wgsl-inout,
wgsl-subpass, wgsl-atomic, subgroup, imagefetch, image-sample, hlsl-matrix, ubo-rowmajor.
VERIFIED GREEN: zig build test exit 0; zig fmt --check clean; GLSL gate valid=1429/INVALID=0/reg=0;
HLSL valid=1406/INVALID=0/reg=0; MSL valid=1430/INVALID=0; WGSL naga PASS=2000/REJECT=0.
(+1 stale #469 Fma test updated to mad lowering.)
REMAINING: switch-edge-cases (workflow flagged: case->default fallthrough GLSL+HLSL +
loop-in-case; WGSL nested-switch honest-error; ALSO discovered MSL shares the default-first
bug A -- separate MSL fix). Not yet cherry-picked (worktree agent returned analysis, not a
clean commit sha). Push = Tier 2 (escalate): 11-commit branch ready as one PR or batched.

## 2026-07-30 FINAL: switch cherry-picked (5abe862) -> 13 commits, ALL GREEN
Switch fix (b253604, was misclassified "failed" only because the fix agent returned
analysis text not the schema; re-verify tasks #58-60 had PASSed build+gates+over-fire)
cherry-picked clean. 13 commits on fix/broad-correctness-hunt. FINAL VERIFY GREEN:
build=0, fmt=0, zig build test=0; GLSL valid=1432/INVALID=0/reg=0; HLSL valid=1409/
INVALID=0/reg=0; MSL valid=1430/INVALID=0; WGSL naga PASS=1999/REJECT=0 (nested_switch
now honest-errors UnsupportedNestedSwitchInSwitchCase = intended).
~17 bug classes / ~37 bugs fixed: #79 phi(5), #78 break(2), Fma+barrier, wgsl-inout,
wgsl-subpass, wgsl-atomic, subgroup-operand+builtin, image-sample Dref Lod/ConstOffset,
hlsl-matrix-nonsquare, imagefetch glsl-ms+hlsl-int3, ubo-nested-rowmajor, switch
(fallthrough-into-default + loop-in-case + nested-switch-honest-error).
REMAINING (1 bounded, NOT fixed): MSL shares switch bug (A) -- spirv_to_msl.zig also
emits default-first, so fallthrough_then_break is silent-wrong in MSL too (the switch
fix was scoped glsl/hlsl/wgsl). Separate MSL-scoped reorder fix; same pattern.
PUSH = Tier 2 (escalate): 13-commit branch fix/broad-correctness-hunt ready.

## 2026-07-30 PUSHED + PR OPEN
All 14 commits (incl. the MSL switch default-last fix, render-MATCH verified) pushed to
origin/fix/broad-correctness-hunt. PR #497 open: https://github.com/zioShade/zioshade/pull/497
(base main). FINAL GREEN: zig build test=0, fmt=0; GLSL 1432/0/0, HLSL 1409/0/0, MSL 1433/0,
WGSL naga 1999/0. Campaign complete; awaiting review/merge.

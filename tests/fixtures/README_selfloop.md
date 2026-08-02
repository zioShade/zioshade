# selfloop_bodyheader — minimal deterministic reproducer for the GLSL phi self-loop bug

A clean, in-bounds, hand-computable fragment shader exercising the
**self-loop-with-body-in-header** pattern: `OpLoopMerge %merge %hdr` where the
continue target IS the loop header (`%hdr`), and the loop body sits IN the
header before the OpLoopMerge. Equivalent to `do { acc += i; } while(++i < 10)`
-> acc = 0+1+...+10 = 55 -> outColor = (55,55,55,1).

## Status (known issue, fully traced)
zioshade REFUSES this (`CrossCompileUnsupported` -- the emitWhileLoop self-loop
recursion, gf032-class). spirv-cross (the reference) handles it correctly
(`for(;;){ acc += i; ... }`). So this is a verifiable case: a correct fix must
make zioshade emit GLSL that (a) compiles, (b) renders MATCH vs spirv-cross,
(c) emits the body exactly ONCE per iteration.

## Why it's hard (3 interlocking defects, all glslang-blind)
An Issue-2a recursion-guard alone (break on the self-loop's own OpLoopMerge)
makes zioshade EMIT, but the output is severely silent-wrong:
1. DOUBLE BODY -- the #237 carry (`if(!_loopfirst){body}`) replays the continue
   (= header) AND the main body emits the header -> body twice per iteration.
2. COUNTER RESET -- the phi init (`int v_phi = 0`) is emitted INSIDE the loop,
   re-initializing the counter each iteration -> INFINITE LOOP.
3. `// unhandled op 250` -- the back-edge BranchConditional, cosmetic.
glslang accepts all of it (different scopes / comments) -> the compile/oracle
gate is structurally blind to it. Only render-diff (vs spirv-cross) or a
structural body-count assertion catches it.

## Fix direction
Route the self-loop through the do-while path (body-then-test IS do-while);
detectDoWhileBackEdge should already match (it scans to the back-edge
BranchConditional a==header b==merge). Then emit the body ONCE inside the loop,
phi-init before the loop, counter update at the continue -- mirroring spirv-cross's
`for(;;){ body; if(!cond) break; advance }`. Gate the fix on this reproducer:
compile + render-MATCH vs spirv-cross + body-count==1 (assert structurally).
Reproduce: `spirv-as selfloop_bodyheader.spvasm -o selfloop_bodyheader.spv`.

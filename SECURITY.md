# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Instead, email **alex@deblasis.net** with:

- A description of the vulnerability and the impact you anticipate.
- A minimal proof-of-concept (GLSL source, SPIR-V binary, or test program) that reproduces.
- The glslpp commit you tested against.

You can expect:

- An acknowledgement within **5 business days**.
- A status update within **15 business days**, including either a fix timeline or an explanation if the issue is being declined.
- Credit in the release notes (unless you prefer to remain anonymous).

## Scope

glslpp is a compiler library. Reports we are particularly interested in:

- Crashes (`@panic`, `unreachable`, stack overflow, OOM-on-fixed-input) reachable from `compileToSPIRV`, `spirvTo*`, or `reflectSPIRV` with attacker-controlled GLSL or SPIR-V input.
- Out-of-bounds reads/writes in the SPIR-V parser or any backend, especially when feeding adversarial SPIR-V binaries.
- Infinite loops or pathological time/memory consumption on small inputs.
- Generated output that compiles to incorrect or unsafe code in the target backend (HLSL/MSL/WGSL/GLSL).

Out of scope:

- Output mismatches against `glslangValidator` or `spirv-cross` — these are correctness issues, please open a regular issue.
- Hardcoded paths or platform-specific behavior in `tools/` development scripts.

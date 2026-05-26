---
name: Bug report
about: Something went wrong — wrong output, crash, or unexpected diagnostic.
title: ''
labels: bug
assignees: ''
---

**Summary**

What did you try to compile / cross-compile, and what went wrong?

**Minimal reproduction**

Smallest GLSL snippet (or attached SPIR-V binary) that triggers the issue:

```glsl
#version 430
// ...
```

**Command you ran**

```bash
zig build cli
zig-out/bin/glslpp ...
```

**Expected vs actual**

- **Expected:** ...
- **Actual:** ... (paste full output if useful)

**Environment**

- glslpp commit: `git rev-parse HEAD`
- Zig version: `zig version`
- OS: Linux / macOS / Windows + version
- Backend involved (if cross-compile): HLSL / GLSL / MSL / WGSL
- `spirv-val` verdict on the input SPIR-V (if applicable): pass / fail with message

**Anything else?**

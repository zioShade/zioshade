# Contributing to glslpp

Thank you for considering a contribution! glslpp is a young, single-contributor project — please read this short guide before opening a PR so we don't waste each other's time.

## Before you start

- For anything beyond a trivial fix or documentation patch, **please open an issue first** describing the change. Many gaps listed in [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) are intentional scope decisions (e.g. WGSL opcode coverage, reflection completeness) — confirming we want the change avoids wasted effort.
- The scope is intentionally narrow: glslpp targets the GLSL surface needed by [wintty](https://github.com/deblasis/wintty) and similar projects. PRs that expand the dialect, add backends, or introduce major optimization passes are welcome, but expect scrutiny on test coverage and conformance impact.

## Toolchain

- **Zig 0.15.2.** A `.mise.toml` is checked in so `mise install` will pull the right version. The `justfile` recipes invoke `mise exec -- zig` to guarantee version pinning.
- **spirv-val** on `PATH` for `zig build conformance` (ships with the Vulkan SDK).
- **DXC** on `PATH` for HLSL backend validation (Vulkan SDK).

## Workflow

1. Fork & branch from `main`.
2. Make focused changes — one logical change per PR.
3. Run the full test suite:
   ```bash
   zig build test
   zig build test-hlsl
   zig build conformance
   ```
4. If you touched the SPIR-V emitter or a cross-compiler, also run:
   ```bash
   zig build fuzz -- --count 5000
   ```
5. Open a PR. The PR description should call out:
   - Why the change is needed.
   - Test coverage added (new fixtures in `tests/conformance/stress/`, regression cases, etc.).
   - Any conformance-count delta (`zig build conformance` → <!-- STATUS:conformance.summary -->2,080 PASS / 7 FAIL / 8 SKIP / 2,095 TOTAL<!-- /STATUS -->; the PASS count must not drop and the FAIL count must not grow — run `just status` to verify). See [docs/STATUS.md](docs/STATUS.md).

## Style

- Match the existing code. Zig is opinionated; `zig fmt` keeps formatting honest.
- Prefer adding fixtures in `tests/conformance/stress/<name>.{f,v,c}.glsl` over inline test strings for new shader features.
- No `@panic` in user-reachable code paths — surface errors through the `Diagnostic` collector or return `error.Foo`.
- Keep `std.debug.print` out of release code. Use `std.log.{warn,err,debug}` so callers can route it.

## Reporting bugs

Open an issue with:
1. The shortest GLSL snippet (or SPIR-V binary) that reproduces.
2. The exact `zig build` command you ran.
3. Expected vs actual output. For cross-compiler bugs, include the spirv-val verdict on the input SPIR-V.

For security issues see [SECURITY.md](SECURITY.md) — do not file a public issue.

## License

By contributing, you agree your contribution will be dual-licensed under MIT and Apache-2.0, matching the project.

# Plan 006: Ship `include/` in the package and prove the C ABI builds from a fetched dependency

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 0816eba..HEAD -- build.zig.zon build.zig .github/workflows/ci.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `0816eba`, 2026-08-03

## Why this matters

> **The identical bug was found and fixed for a different file, then the check
> was certified closed too narrowly.** PR #492 (2026-07-29, "build on Zig 0.16
> and ship build_compat.zig in the package") caught that `build.zig` imports
> `build_compat.zig` from the repo root while `.paths` listed only `build.zig`,
> `build.zig.zon`, and `src`, so every fetching consumer hit
> `error: unable to load 'build_compat.zig': FileNotFound`. The review then
> concluded the `.paths` addition was complete on the grounds that `build.zig`
> imports only `std`, `builtin`, and `build_compat.zig`. That reasoning checked
> `build.zig`'s **Zig imports** and never considered `b.path("include")`, which
> is a filesystem dependency rather than an import. So `include/` was not
> consciously deferred; it was missed by a check that looked at the wrong axis.
> The CI job in step 3 is what makes the axis irrelevant.

The README documents `zig build c-lib` as the way to obtain the C ABI, and the
C ABI is how any non-Zig consumer uses this project. But the package manifest
does not ship the `include/` directory, so a consumer who adds zioshade with
`zig fetch` gets a package where that build step fails on a missing path. CI
never catches it because every job runs from a full `actions/checkout` of the
repository, not from the packaged tarball, so the packaged artifact has never
been exercised.

This is small, but it is the difference between a dependency that works when
someone tries it and one that fails at the first step. The fix is two lines plus
a CI job that makes the packaged form a tested surface rather than an assumed
one.

## Current state

**The manifest excludes `include/` and `examples/`.** `build.zig.zon:20-25`:

```zig
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "build_compat.zig",
        "src",
    },
```

`.paths` is the exhaustive list of what gets published. Anything absent does not
exist in a fetched copy.

**Two build steps depend on the missing directories.** `build.zig:171-175` (the
`c-lib` step):

```zig
        .source_dir = b.path("include"),
```

installed via `addInstallDirectory(... .install_dir = .header)`.

`build.zig:193` and `build.zig:196` (the `c-example` step) compile
`b.path("examples/c/main.c")` and call `addIncludePath(b.path("include"))`.

**CI runs only from a checkout.** The `c-abi` job at
`.github/workflows/ci.yml:232` builds and runs the C example on all three
operating systems, but it starts from `actions/checkout`, where `include/` is
present. The packaged form is never built.

**Version and changelog are also out of sync**, which matters because the
package hash changes when `.paths` changes. `build.zig.zon:3` says `0.4.0`;
`git tag -l` shows `v0.3.0` and `v0.4.0`; `git log v0.4.0..HEAD --oneline | wc -l`
returns **48**. `CHANGELOG.md:5-7` has `## [Unreleased]` followed by
`(nothing yet)`, and `git log -1 -- CHANGELOG.md` shows it untouched since the
v0.4.0 release commit. The primary consumer (wintty) tracks latest, so it is
consuming 48 commits of behavior changes with no release notes.

Repo conventions to match:

- `.paths` entries are directory or file names relative to the repository root,
  as plain strings.
- `CHANGELOG.md` follows Keep a Changelog with a SemVer promise stated at
  `CHANGELOG.md:3` covering the public API exported from `src/root.zig`.
- Conventional-commit messages with a trailing PR number.
- **No AI attribution in commits**: do not add `Co-Authored-By` trailers.
- **Do not use em dashes** in code comments, changelog entries, commit messages,
  or docs.
- Zig 0.15.2 via mise; prefix builds with `mise exec --`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format check | `mise exec -- zig fmt --check src` | exit 0 |
| Unit tests | `mise exec -- zig build test` | exit 0 |
| C library | `mise exec -- zig build c-lib` | exit 0 |
| C example | `mise exec -- zig build c-example` | exit 0 |
| Strict gate | `mise exec -- zig build strict-gate` | exit 0, PASS 2108, XFAIL 13 |

## Scope

**In scope** (the only files you should modify):
- `build.zig.zon`
- `.github/workflows/ci.yml`
- `CHANGELOG.md`

**Out of scope** (do NOT touch, even though they look related):
- `build.zig` - the build steps are correct; the manifest is what is wrong.
- Creating a release workflow or git tags. Tagging and publishing is a
  maintainer decision (it is outward-facing and irreversible). This plan
  prepares the changelog only; it does not release.
- `README.md` version references and the stale documentation numbers found in
  the audit. Separate concern, tracked in the backlog.
- Bumping the version to `0.5.0`. Only set the `-dev` suffix as described in
  step 4, and only if the maintainer convention supports it (see STOP
  conditions).

## Git workflow

- Branch: `advisor/006-package-integrity`
- Commit per step, conventional-commit style, for example
  `build: ship include/ and examples/ in the package manifest`
- Do NOT push, tag, or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the missing directories to `.paths`

In `build.zig.zon`, extend `.paths`:

```zig
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "build_compat.zig",
        "include",
        "src",
        "examples",
    },
```

`include` is required for `c-lib`. `examples` is required for `c-example`; add
it so the documented example is usable from a fetched copy. If including
`examples/` inflates the package unacceptably (check its size with
`du -sh examples/`), include it anyway unless it exceeds a few hundred
kilobytes, and note the size in your report.

**Verify**:
- `mise exec -- zig build c-lib` -> exit 0
- `mise exec -- zig build c-example` -> exit 0

### Step 2: Verify the packaged form actually builds

Reproduce locally what a consumer experiences. Create the archive the way `zig
fetch` consumes one and build `c-lib` from the extracted copy in a scratch
directory outside the repository. Use the scratch directory
`/tmp/zioshade-pkg-smoke` (create it; do not write anywhere inside the repo).

A workable sequence:

```bash
rm -rf /tmp/zioshade-pkg-smoke && mkdir -p /tmp/zioshade-pkg-smoke
git archive --format=tar.gz -o /tmp/zioshade-pkg-smoke/pkg.tar.gz HEAD
```

Then extract only the paths listed in `.paths` into a fresh directory (this
simulates the published package, since `git archive` includes everything
tracked), and run `mise exec -- zig build c-lib` there.

The essential assertion: **a tree containing only the `.paths` entries builds
`c-lib` successfully.** If simulating that precisely proves fiddly, the simpler
equivalent is to copy exactly the `.paths` entries into a fresh directory and
build there.

**Verify**: `mise exec -- zig build c-lib` inside the scratch copy -> exit 0, and
the installed header appears in that copy's `zig-out/include/`.

Confirm the check has teeth: temporarily remove `"include"` from the scratch
copy's `build.zig.zon` `.paths` and delete its `include/` directory, then rebuild
and confirm it fails. Restore. Record both outcomes in your report.

### Step 3: Add a package smoke job to CI

Add a job to `.github/workflows/ci.yml` that performs step 2's check
automatically. Model its structure (checkout, `mlugg/setup-zig` with the pinned
version, then run steps) on the existing `c-abi` job at `ci.yml:232`.

The job should:

1. Check out the repository.
2. Set up Zig 0.15.2, using the same pinned version string the neighbouring jobs
   use.
3. Assemble a directory containing only the `.paths` entries.
4. Run `zig build c-lib` in that directory.
5. Assert the header was installed (for example, test for the existence of
   `zig-out/include/zioshade.h`).

Linux only is sufficient; this validates packaging, not platform support.

**Verify**:
- `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"`
  -> exit 0
- `grep -c "c-lib" .github/workflows/ci.yml` -> at least 1

### Step 4: Backfill the changelog

Populate `## [Unreleased]` in `CHANGELOG.md` from the 48 commits since the
v0.4.0 tag:

```bash
git log v0.4.0..HEAD --oneline
```

Group entries under Keep a Changelog headings (`Added`, `Fixed`, `Changed`),
matching the formatting of the existing v0.4.0 section. Focus on user-visible
behavior: the identifier-mangling changes (`ab5621e`, `b2ac34a`, `35456d9`,
`0b8d58c`), the self-loop lowering and HLSL honest-error (`0816eba`), the WGSL
fixes, and the CLI diagnostic improvements. Do not list internal test or tooling
commits individually; one summary line for those is enough.

Call out the identifier-mangling changes explicitly under `Changed`: they alter
generated output for consumers pinning a specific version, which is exactly what
a downstream reader needs to know.

Add one line noting that `include/` and `examples/` are now shipped in the
package.

**Verify**: `grep -A 5 "## \[Unreleased\]" CHANGELOG.md` -> shows real entries,
not `(nothing yet)`.

### Step 5: Run the full gate

**Verify**: all of the following exit 0:
- `mise exec -- zig fmt --check src`
- `mise exec -- zig build test`
- `mise exec -- zig build c-lib`
- `mise exec -- zig build c-example`
- `mise exec -- zig build strict-gate` (PASS 2108, XFAIL 13)

## Test plan

The test for this plan is the CI job added in step 3: it is a build-level
assertion that the packaged form is usable. No unit tests are appropriate here,
since the defect is in packaging metadata rather than in code.

The teeth check in step 2 (remove `include`, confirm failure, restore) is the
manual proof that the new job would have caught the original bug.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `mise exec -- zig fmt --check src` exits 0
- [ ] `mise exec -- zig build test` exits 0
- [ ] `mise exec -- zig build c-lib` exits 0
- [ ] `mise exec -- zig build c-example` exits 0
- [ ] `mise exec -- zig build strict-gate` exits 0, PASS 2108, XFAIL 13
- [ ] `grep -c '"include"' build.zig.zon` returns 1
- [ ] `grep -c '"examples"' build.zig.zon` returns 1
- [ ] A `.paths`-only copy of the tree builds `c-lib` successfully (step 2)
- [ ] The new CI job exists and the workflow YAML parses
- [ ] `grep -A 3 "## \[Unreleased\]" CHANGELOG.md` does not contain
      `(nothing yet)`
- [ ] No files outside the in-scope list are modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `build.zig.zon:20-25` does not match the excerpt above.
- The `.paths`-only copy still fails to build `c-lib` after adding `include`.
  That means something else is also missing from the manifest. Report exactly
  what path the build asks for; do not add paths one at a time by trial and
  error beyond a second attempt.
- Adding `examples` to `.paths` makes the package unreasonably large (check
  `du -sh examples/`). Ship `include` alone, note the decision in your report,
  and leave `c-example` documented as checkout-only.
- You are tempted to create a git tag, bump the version to a release number, or
  push anything. Do not. Releasing is outward-facing and is the maintainer's
  call. If a `-dev` version suffix seems warranted, propose it in your report
  rather than applying it.
- The changelog backfill requires judgment about whether a change is breaking.
  Write what the commit did factually and flag the ambiguity in your report
  rather than asserting a SemVer classification.

## Maintenance notes

- **`.paths` is a denylist by omission**: anything not listed silently vanishes
  from the published package. Whenever a build step gains a dependency on a new
  top-level directory, `.paths` needs the entry, and the CI job added here is
  what will catch the omission. A reviewer should check `.paths` on any PR that
  adds a `b.path("...")` reference to a new top-level directory.
- The remaining half of this problem is deliberately out of scope: there is no
  tag-to-artifact release process, so the C ABI static and shared libraries plus
  the header are not attached to any GitHub release. The `c-abi` job already
  builds them green on all three operating systems, so a release workflow is
  largely a re-use of that matrix. That is the natural follow-up.
- Changing `.paths` changes the package hash. Any consumer pinning zioshade by
  hash must update it. Since the next version has not been published, this is
  free now and expensive later.

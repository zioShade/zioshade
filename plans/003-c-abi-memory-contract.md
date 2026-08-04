# Plan 003: Make C ABI buffers safe to free from any thread, and give malformed input an honest status code

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 0816eba..HEAD -- src/c_abi.zig include/zioshade.h tests/c_abi_tests.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: plans/001-verification-baseline.md
- **Category**: security
- **Planned at**: commit `0816eba`, 2026-08-03

## Why this matters

> **This is a known finding that was raised and then lost.** The pre-go-public
> security audit of 2026-07-07 flagged it as HIGH, with the same diagnosis:
> *"HIGH: cross-thread free corrupts the heap. Allocator is `threadlocal`
> (c_abi.zig:52); `zioshade_free_*` routes through the calling thread's GPA. A
> buffer allocated on a worker thread and freed on the UI thread -> corruption"*,
> and *"The single most dangerous footgun is cross-thread free, and it is
> undocumented."* It was carried in the workflow context alongside the C1-C5
> hardening items but is **absent from the PR #422 fix set** that shipped those
> items, and absent from the wave-completion report. It has been open ever since.
>
> It also got harder to see: `include/zioshade.h:27-31` now states *"Concurrent
> calls from different threads are safe"* with no mention of the
> free-on-allocating-thread constraint, so the documentation currently
> contradicts the code. Step 6 fixes that, and it is not optional cleanup.

The C ABI is the surface external consumers link against, and its header
promises thread-safety. It allocates every returned buffer from a **threadlocal**
allocator and frees it through the **freeing thread's** allocator. The natural
host pattern, compile shaders on a worker or startup thread and release the
buffers on the main thread, therefore hands a `DebugAllocator` a pointer it never
allocated. That is heap corruption, or a hard `Invalid free` abort inside the
host process. The header never warns against it; it says concurrent use is safe.

Separately, every uncategorised error collapses to `ZIOSHADE_ERR_CODEGEN`, so a
host cannot distinguish "the SPIR-V you gave me is corrupt" (reject the input)
from "this construct is unsupported" (fall back to another backend) from
"internal compiler bug" (file a report). For a project whose contract is "honest
error, never miscompile", the one boundary external consumers actually see does
not carry an honest error.

Both are small, self-contained fixes at the ABI layer with no compiler changes.

## Current state

**The allocator is threadlocal and both alloc and free route through it.**
`src/c_abi.zig:48-95`:

```zig
// Each thread that touches the C ABI gets its own GeneralPurposeAllocator.
// We never reset or deinit it - C callers manage the lifetime of returned
// buffers via the `zioshade_free_*` helpers, and the GPA itself lives until
// process exit. This matches what consumers of a typical C library expect.

threadlocal var gpa: compat.Gpa(.{}) = .{};

fn alloc() std.mem.Allocator {
    return gpa.allocator();
}
```

`compat.Gpa` is `std.heap.DebugAllocator` (`src/compat.zig:44`).

```zig
const PREFIX: usize = 8;

fn allocBytes(n: usize) ?[*]u8 {
    const a = alloc();
    const buf = a.alignedAlloc(u8, .of(u64), PREFIX + n) catch return null;
    std.mem.writeInt(u64, buf[0..8], @as(u64, n), .little);
    return buf.ptr + PREFIX;
}

fn freeBytes(p: ?[*]u8) void {
    const raw = p orelse return;
    const start = raw - PREFIX;
    const n: usize = @intCast(std.mem.readInt(u64, start[0..8], .little));
    const aligned: [*]align(8) u8 = @ptrCast(@alignCast(start));
    alloc().free(aligned[0 .. PREFIX + n]);
}
```

`allocBytes` calls `alloc()` on the allocating thread; `freeBytes` calls
`alloc()` on the freeing thread. Different threads, different GPAs.
`zioshade_free_str` (`src/c_abi.zig:477`) and `zioshade_free_u32`
(`src/c_abi.zig:483`) both route through `freeBytes`.

**The header promises thread-safety without stating the constraint.**
`include/zioshade.h:25-31`:

```c
// will see a bogus header. Always use the zioshade_free_* helpers.
//
// Thread-safety
// -------------
// Each call manages its own arena via a threadlocal allocator. Concurrent
// calls from different threads are safe. The `zioshade_last_error_*` getters
// read threadlocal state owned by the calling thread.
```

Nothing tells the caller that a buffer must be released on the thread that
produced it.

**All uncategorised errors become `ZIOSHADE_ERR_CODEGEN`.**
`src/c_abi.zig:154-166`:

```zig
fn statusFromErr(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => ZIOSHADE_ERR_OOM,
        error.LexFailed => ZIOSHADE_ERR_LEX,
        error.PreprocessFailed => ZIOSHADE_ERR_PREPROCESS,
        error.ParseFailed => ZIOSHADE_ERR_PARSE,
        error.SemanticFailed => ZIOSHADE_ERR_SEMANTIC,
        error.CodegenFailed, error.EntryPointNotFound => ZIOSHADE_ERR_CODEGEN,
        // Backend cross-compile errors (CrossCompileUnsupported, etc.) and
        // anything else we haven't categorised gets bucketed as codegen.
        else => ZIOSHADE_ERR_CODEGEN,
    };
}
```

The SPIR-V validity errors that exist and are reachable
(`src/spirv_cross_common.zig:42,43,66`): `error.InvalidSpirv`,
`error.InvalidSpirvMagic`, `error.InvalidSpirvTruncated`.

**Input validation does not check the magic word.** `src/c_abi.zig:301-305`
(`validateSpirvInputs`) checks only that the pointer is non-null and the word
count is at least 5, so a corrupt blob is rejected deep inside a backend rather
than cheaply at the boundary.

**`ZIOSHADE_ERR_INVALID_INPUT` already exists** and `include/zioshade.h:94`
documents it as covering "NULL pointers, out-of-range enums, zero-length
SPIR-V, etc." - malformed binaries belong here and never reach it.

Repo conventions to match:

- Status-code constants are `ZIOSHADE_ERR_*` in both `src/c_abi.zig` (around
  line 36) and `include/zioshade.h`. They must stay in sync; the header is the
  published contract.
- The existing C ABI tests are `tests/c_abi_tests.zig`, and CI has a dedicated
  `c-abi` job (`.github/workflows/ci.yml:232`) that builds and runs the C
  example on all three OSes.
- Conventional-commit messages with a trailing PR number.
- **No AI attribution in commits**: do not add `Co-Authored-By` trailers.
- **Do not use em dashes** in code comments, headers, or commit messages.
- Zig 0.15.2 via mise; prefix builds with `mise exec --`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format check | `mise exec -- zig fmt --check src` | exit 0 |
| Unit tests | `mise exec -- zig build test` | exit 0, all pass |
| C library | `mise exec -- zig build c-lib` | exit 0 |
| C example | `mise exec -- zig build c-example` | exit 0, runs clean |
| Strict gate | `mise exec -- zig build strict-gate` | exit 0, PASS 2108, XFAIL 13 |

## Scope

**In scope** (the only files you should modify):
- `src/c_abi.zig`
- `include/zioshade.h`
- `tests/c_abi_tests.zig`

**Out of scope** (do NOT touch, even though they look related):
- `src/compat.zig` - `Gpa`/`DebugAllocator` is used by more than the C ABI;
  changing it there has repo-wide blast radius. Make the change local to
  `c_abi.zig`.
- The threadlocal `last_error` state. Per-thread error reporting is correct and
  conventional (it mirrors `errno`); leave it threadlocal.
- `src/wasm.zig` - it has its own allocator story and a separate defect covered
  in the backlog.
- Any file under `src/spirv_to_*.zig` or the compiler proper. This plan changes
  no compilation behavior.
- Renumbering or repurposing any existing `ZIOSHADE_ERR_*` value. Existing
  values are ABI; you may add a new one, never change an old one.

## Git workflow

- Branch: `advisor/003-c-abi-memory-contract`
- Commit per step, conventional-commit style, for example
  `fix(c-abi): allocate caller-owned buffers from a process-global allocator`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Move caller-owned buffers to a process-global allocator

In `src/c_abi.zig`, add a process-wide allocator used **only** by `allocBytes`
and `freeBytes`. Keep the threadlocal `gpa` for internal scratch work so the
per-call arena behavior described in the header comment stays true.

Preferred approach (simplest, no lock):

```zig
/// Caller-owned buffers are allocated here, never from the threadlocal GPA:
/// a C consumer may free on a different thread than the one that compiled.
const result_allocator = std.heap.smp_allocator;
```

If `std.heap.smp_allocator` is not available on the pinned Zig 0.15.2, use a
mutex-guarded shared allocator instead:

```zig
var result_gpa: compat.Gpa(.{}) = .{};
var result_mutex: std.Thread.Mutex = .{};
```

and take the lock in both `allocBytes` and `freeBytes`. One lock per returned
buffer is negligible next to a full shader compile.

Change `allocBytes` to allocate from the new allocator and `freeBytes` to free
from it. Update the comment block at `src/c_abi.zig:48-51` to state the new
split: threadlocal for scratch, process-global for anything the caller owns.

**Verify**:
- `mise exec -- zig build test` -> exit 0
- `mise exec -- zig build c-lib` -> exit 0
- `mise exec -- zig build c-example` -> exit 0, runs clean

### Step 2: Add a cross-thread alloc/free regression test

In `tests/c_abi_tests.zig`, add a test that:

1. Spawns a thread with `std.Thread.spawn`.
2. On that thread, calls the public compile entry point (the same one
   `tests/c_abi_tests.zig` already exercises) to obtain a caller-owned buffer,
   and hands the pointer back to the main thread.
3. On the main thread, calls `zioshade_free_str` (or `zioshade_free_u32`, match
   the buffer type) on that pointer.
4. Asserts the process does not abort and the contents were readable before the
   free.

Repeat the round trip in a loop (at least 50 iterations) so an allocator
mismatch is likely to trip the `DebugAllocator`'s safety checks rather than
passing by luck.

Model the test-block style and allocator handling on the existing tests in
`tests/c_abi_tests.zig`.

**Verify**: `mise exec -- zig build test` -> exit 0, new test passes. Confirm the
test actually fails against the old code by stashing your step 1 change
(`git stash`), running the test (expect a failure or abort), then restoring
(`git stash pop`). Record both outcomes in your report. If the test passes
against the old code, it is not exercising the defect; fix the test.

### Step 3: Route SPIR-V validity errors to `ZIOSHADE_ERR_INVALID_INPUT`

In `src/c_abi.zig:154-166`, add an arm before the `else`:

```zig
        error.InvalidSpirv,
        error.InvalidSpirvMagic,
        error.InvalidSpirvTruncated,
        => ZIOSHADE_ERR_INVALID_INPUT,
```

**Verify**: `mise exec -- zig build test` -> exit 0.

### Step 4: Add `ZIOSHADE_ERR_UNSUPPORTED` for honest-error refusals

Add a **new** status constant (do not reuse or renumber an existing value) in
both `src/c_abi.zig` (near the other `ZIOSHADE_ERR_*` definitions around line 36)
and `include/zioshade.h`. Give it the next unused numeric value.

Route the honest-error family to it in `statusFromErr`:
`error.CrossCompileUnsupported` and the `error.Unsupported*` errors. Find the
exact set with:

```bash
grep -rhoE "error\.(Unsupported[A-Za-z]*|CrossCompileUnsupported)" src/ | sort -u
```

Leave the final `else => ZIOSHADE_ERR_CODEGEN` in place as the catch-all.

Document the new code in `include/zioshade.h` next to the existing status
documentation, in the same comment style: it means the input was valid but
contains a construct this backend cannot faithfully translate, and the correct
caller response is to try a different backend or report the shader, not to
retry.

**Verify**:
- `grep -c ZIOSHADE_ERR_UNSUPPORTED src/c_abi.zig include/zioshade.h` -> at least
  1 in each
- `mise exec -- zig build c-lib` -> exit 0
- `mise exec -- zig build test` -> exit 0

### Step 5: Check the SPIR-V magic word at the boundary

In `validateSpirvInputs` (`src/c_abi.zig:301-305`), after the existing null and
minimum-length checks, verify `spirv_words[0] == spirv.MAGIC` and return
`ZIOSHADE_ERR_INVALID_INPUT` when it does not match. This rejects a corrupt blob
before any allocation happens.

The magic constant is `spirv.MAGIC`, used at `src/spirv_cross_common.zig:43`.

**Verify**: `mise exec -- zig build test` -> exit 0.

### Step 6: Update the header's thread-safety contract

In `include/zioshade.h:27-31`, replace the thread-safety paragraph so it states
what is now true:

- Concurrent calls from different threads are safe.
- Buffers returned by any `zioshade_*` call may be released with the matching
  `zioshade_free_*` helper **from any thread**, not only the producing thread.
- `zioshade_last_error_*` remains threadlocal and reports the calling thread's
  most recent error.

Keep the existing comment style. Do not use em dashes.

**Verify**:
- `mise exec -- zig build c-lib` -> exit 0
- `mise exec -- zig build c-example` -> exit 0

### Step 7: Run the full gate

**Verify**: all of the following exit 0:
- `mise exec -- zig fmt --check src`
- `mise exec -- zig build test`
- `mise exec -- zig build c-lib`
- `mise exec -- zig build c-example`
- `mise exec -- zig build strict-gate` (PASS 2108, XFAIL 13, unchanged)

## Test plan

New tests in `tests/c_abi_tests.zig`, following the existing structure there:

- **Cross-thread free** (step 2): allocate on a spawned thread, free on the
  main thread, 50+ iterations. This is the regression test for the primary
  defect and must be demonstrated to fail against the pre-fix code.
- **Malformed magic**: pass a word array whose first word is not the SPIR-V
  magic and assert the status is `ZIOSHADE_ERR_INVALID_INPUT`, not
  `ZIOSHADE_ERR_CODEGEN`.
- **Truncated module**: pass a 3-word array and assert
  `ZIOSHADE_ERR_INVALID_INPUT`.
- **Unsupported construct**: if `tests/` already has a fixture that triggers a
  documented honest-error refusal, assert it now yields
  `ZIOSHADE_ERR_UNSUPPORTED`. If no such fixture is readily available, skip this
  case and say so in your report rather than constructing one.
- **Positive control**: a valid module still returns success and non-null output.

**Verification**: `mise exec -- zig build test` -> all pass, 4 or 5 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `mise exec -- zig fmt --check src` exits 0
- [ ] `mise exec -- zig build test` exits 0, including the cross-thread test
- [ ] `mise exec -- zig build c-lib` exits 0
- [ ] `mise exec -- zig build c-example` exits 0
- [ ] `mise exec -- zig build strict-gate` exits 0, PASS 2108, XFAIL 13
- [ ] `allocBytes` and `freeBytes` no longer call the threadlocal `alloc()`:
      `grep -n "fn allocBytes" -A 8 src/c_abi.zig` shows the process-global
      allocator
- [ ] `grep -c ZIOSHADE_ERR_UNSUPPORTED include/zioshade.h` returns at least 1
- [ ] `grep -n "InvalidSpirvTruncated" src/c_abi.zig` shows it mapping to
      `ZIOSHADE_ERR_INVALID_INPUT`
- [ ] The header no longer implies buffers are thread-bound
      (`grep -n "any thread" include/zioshade.h` returns a match)
- [ ] No existing `ZIOSHADE_ERR_*` numeric value changed
      (`git diff include/zioshade.h` shows only additions to the constant list)
- [ ] No files outside the in-scope list are modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts at `src/c_abi.zig:48-95`, `:154-166`, or `include/zioshade.h:25-31`
  do not match the live code.
- `std.heap.smp_allocator` does not exist on the pinned Zig 0.15.2 **and** the
  mutex-guarded fallback does not compile cleanly on both 0.15.2 and 0.16. This
  project maintains dual-version support via `src/compat.zig`; if the allocator
  choice needs a version shim, that belongs in `compat.zig`, which is out of
  scope for this plan. Report and stop.
- The cross-thread test in step 2 **passes** against the pre-fix code. That means
  it is not reaching the defect and the fix is unverified.
- Re-bucketing errors in step 3 or 4 changes the status code returned for any
  case covered by an existing test in `tests/c_abi_tests.zig`. Existing status
  codes are ABI; a changed value for an existing case needs a maintainer
  decision, not an executor decision.
- You cannot determine the complete `error.Unsupported*` set from the grep in
  step 4. Route only the ones you can confirm and list the rest in your report.

## Maintenance notes

- **The split matters**: threadlocal for internal scratch, process-global for
  anything handed to the caller. Any future `zioshade_*` function returning
  caller-owned memory must use `allocBytes`, never the threadlocal `gpa`
  directly. A reviewer should check this on every new ABI entry point.
- Adding `ZIOSHADE_ERR_UNSUPPORTED` is additive and safe for existing consumers
  reading unknown codes as generic failure, but a consumer that switches
  exhaustively on the old set will now hit a default branch. Note it in
  `CHANGELOG.md` when the next release goes out.
- The threadlocal `gpa` is still never deinitialised, so a host that spawns a
  thread per compile still accumulates one arena per thread. After this change
  those arenas hold only scratch, not caller buffers, so the leak is bounded and
  much smaller, but it is not zero. Fixing it properly means an explicit
  `zioshade_thread_shutdown()` entry point, deliberately deferred as an API
  addition needing maintainer sign-off.
- Deliberately deferred: the length-prefix layout means passing a foreign
  pointer to `zioshade_free_*` reads a bogus header. That is documented as
  undefined behavior at `include/zioshade.h:370-387` and is a legitimate C
  library convention; no change recommended.

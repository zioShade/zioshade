# zioshade WASM playground

A static, framework-free browser playground for zioshade: type a GLSL fragment
shader on the left, see it cross-compiled to HLSL, MSL, GLSL, and WGSL on the
right. All compilation runs client-side in a WebAssembly build of the zioshade
library; nothing is sent to a server.

## Status

This is a scaffold. What is proven and what is not:

- Proven: the wasm module compiles. `zig build wasm` produces
  `zig-out/bin/zioshade-playground.wasm` (a wasm32-freestanding reactor module),
  and its export section carries `zs_alloc`, `zs_free`, `zs_compile`,
  `zs_result_ptr`, `zs_result_len`, and `memory`.
- Not yet proven: the browser UI. `index.html` and `playground.js` have not been
  run in a real browser. The JS boundary glue is written against the documented
  ABI but has not been exercised end to end.

## How the pieces fit

- `src/wasm.zig` (in the repo root) is the wasm entry module. It exports a thin
  C-ABI surface over the existing public API (`compileGlslToHlsl` and friends in
  `src/root.zig`) and manages linear-memory buffers with
  `std.heap.wasm_allocator`.
- `build.zig` has a `wasm` step that targets `wasm32-freestanding`, disables the
  entry point, and keeps the exported symbols (`rdynamic`).
- `web/index.html` + `web/playground.js` are the static harness. The JS loads the
  `.wasm`, allocates a buffer, writes the UTF-8 source in, calls `zs_compile`,
  and reads the result back out with `TextDecoder`.

## Build and try locally

```sh
# from the repo root
zig build wasm
cp zig-out/bin/zioshade-playground.wasm web/

# serve the web/ directory over HTTP (instantiateStreaming needs a real
# server and the application/wasm MIME type; file:// will not work)
cd web
python3 -m http.server 8000
# open http://localhost:8000
```

The copy step is deliberate: `playground.js` fetches
`zioshade-playground.wasm` from its own directory, so the built artifact has to
sit next to the HTML. A future revision can add a `web-bundle` build step that
installs the `.wasm` into `web/` automatically.

## What remains

1. Browser testing. Load the page, confirm the wasm instantiates, and verify
   each of the four backend tabs renders sensible output for a few real shaders.
   Watch for: memory-detachment bugs after `memory.grow` (the JS re-creates its
   `Uint8Array` views on every read for this reason, but it is unverified), and
   correct handling of compile errors (a negative `zs_compile` status should
   show the stashed error string, styled red).
2. Stage selection. `zs_compile` currently hard-codes the fragment stage. To
   support vertex/compute/etc., thread a stage argument through the ABI and add a
   selector to the UI.
3. GitHub Pages deploy. The repo is private, so decide whether the playground
   ships from a public mirror or stays internal. A minimal workflow would run
   `zig build wasm`, copy the artifact into `web/`, and publish `web/` as the
   Pages artifact. Do not enable Pages on the private repo without confirming the
   privacy expectations for this project first.
4. Bundle-size trim. The module is a few megabytes because it links the whole
   compiler. `ReleaseSmall` is already selected; `wasm-opt -Oz` from Binaryen and
   `wasm-strip` can shave it further as a post-build step if size matters.

## Notes

- Includes: filesystem-backed `#include` resolution is compiled out on
  freestanding wasm (no `std.fs`). Shaders in the playground should be
  self-contained, or supply includes through the `file_reader` callback if that
  path is ever wired to the JS side.
- Logging: the library's internal `std.log` calls are routed to a no-op logger
  in the wasm build (there is no stderr in a bare wasm module). Compile failures
  still reach the UI through `zs_compile`'s return status and error string.

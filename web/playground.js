// zioshade playground — browser glue for the wasm module built by
// `zig build wasm` (src/wasm.zig). No framework, no build step: this file is
// served as-is next to zioshade-playground.wasm.
//
// UNTESTED IN A BROWSER. The wasm module is known to compile (that is the
// project gate); wiring it up end-to-end in a real browser is the remaining
// work tracked in web/README.md.
//
// Boundary protocol (mirrors the doc comment in src/wasm.zig):
//   - zs_alloc(len) -> ptr     reserve `len` bytes, returns offset (0 = OOM)
//   - zs_free(ptr, len)        release a zs_alloc buffer
//   - zs_compile(be, ptr, len) -> status  0 = ok, negative = error
//   - zs_result_ptr() -> ptr   offset of result (or error) bytes
//   - zs_result_len() -> len   byte length of result (or error)
// Strings cross as UTF-8 in the module's linear memory.

// Backend selector values. Keep in sync with the `Backend` enum in
// src/wasm.zig.
const BACKENDS = [
  { id: 0, key: "hlsl", label: "HLSL" },
  { id: 1, key: "msl", label: "MSL" },
  { id: 2, key: "glsl", label: "GLSL" },
  { id: 3, key: "wgsl", label: "WGSL" },
];

const DEFAULT_SHADER = `#version 430
layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 uv;

void main() {
    vec3 col = 0.5 + 0.5 * cos(vec3(uv.x, uv.y, uv.x + uv.y) * 6.2831853);
    fragColor = vec4(col, 1.0);
}
`;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const els = {
  source: document.getElementById("source"),
  output: document.getElementById("output"),
  status: document.getElementById("status"),
  tabs: document.getElementById("tabs"),
  run: document.getElementById("run"),
  auto: document.getElementById("auto"),
};

let wasm = null; // { exports, memory }
let activeBackend = BACKENDS[0];

function setStatus(text, kind) {
  els.status.textContent = text;
  els.status.className = "status" + (kind ? " " + kind : "");
}

// Read `len` bytes at `ptr` from the module's linear memory as a UTF-8 string.
// A fresh Uint8Array view is taken each time because memory.grow can detach the
// old ArrayBuffer.
function readString(ptr, len) {
  const bytes = new Uint8Array(wasm.memory.buffer, ptr, len);
  return decoder.decode(bytes);
}

// Compile the current source to `backend` and return { ok, text }.
function compileTo(backend) {
  const src = encoder.encode(els.source.value);
  const ptr = wasm.exports.zs_alloc(src.length);
  if (ptr === 0 && src.length > 0) {
    return { ok: false, text: "wasm allocation failed (out of memory)" };
  }
  try {
    // Copy the source bytes into linear memory at the reserved offset.
    new Uint8Array(wasm.memory.buffer, ptr, src.length).set(src);
    const status = wasm.exports.zs_compile(backend.id, ptr, src.length);
    const rptr = wasm.exports.zs_result_ptr();
    const rlen = wasm.exports.zs_result_len();
    const text = rlen > 0 ? readString(rptr, rlen) : "";
    return { ok: status === 0, text };
  } finally {
    // Release only the input buffer; the result buffer is owned by the module.
    wasm.exports.zs_free(ptr, src.length);
  }
}

function render() {
  if (!wasm) return;
  const { ok, text } = compileTo(activeBackend);
  els.output.textContent = ok
    ? text || "(empty output)"
    : text || "(compile failed with no message)";
  els.output.classList.toggle("error", !ok);
  if (ok) {
    setStatus("compiled " + activeBackend.label, "ok");
  } else {
    setStatus("error", "err");
  }
}

function buildTabs() {
  for (const be of BACKENDS) {
    const btn = document.createElement("button");
    btn.className = "tab" + (be === activeBackend ? " active" : "");
    btn.textContent = be.label;
    btn.addEventListener("click", () => {
      activeBackend = be;
      for (const child of els.tabs.children) child.classList.remove("active");
      btn.classList.add("active");
      render();
    });
    els.tabs.appendChild(btn);
  }
}

async function loadWasm() {
  // A reactor module has no _start; we only need its exports. No imports are
  // required by src/wasm.zig, so the import object is empty.
  const resp = await fetch("zioshade-playground.wasm");
  const { instance } = await WebAssembly.instantiateStreaming(resp, {});
  wasm = { exports: instance.exports, memory: instance.exports.memory };
}

function debounce(fn, ms) {
  let t = null;
  return () => {
    clearTimeout(t);
    t = setTimeout(fn, ms);
  };
}

async function main() {
  els.source.value = DEFAULT_SHADER;
  buildTabs();
  try {
    await loadWasm();
  } catch (err) {
    setStatus("failed to load wasm", "err");
    els.output.textContent = String(err);
    els.output.classList.add("error");
    return;
  }
  setStatus("ready", "ok");
  els.run.addEventListener("click", render);
  const debounced = debounce(render, 250);
  els.source.addEventListener("input", () => {
    if (els.auto.checked) debounced();
  });
  render();
}

main();

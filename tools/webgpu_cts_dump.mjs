// WebGPU CTS per-case WGSL dumper (r2d.1).
//
// The webgpu:shader suite has NO standalone WGSL corpus: every test's WGSL is
// assembled inside the CTS TypeScript framework and compiled by the
// implementation under test via t.expectCompileResult(expected, code) ->
// device.createShaderModule({code}). Running that for real needs a GPU; the
// point of this dumper is to capture the EXACT per-case shader text WITHOUT
// one, so zioshade's SPIR-V -> WGSL backend can be fed the CTS's own corpus
// (round-tripped WGSL -> naga -> SPIR-V first, since zioshade does not ingest
// WGSL).
//
// Mechanism: this runs against a tsc JS emission of the CTS src tree (see
// tools/webgpu_cts_fetch.sh), imports every validation spec module, and drives
// the framework's own case enumeration (g.iterate() -> test.iterate(null)) so
// params expand exactly as they would in a real run. For each case it builds
// the fixture instance by hand and invokes the stored test fn with:
//   - GPUTestSubcaseBatchState.acquireProvider/finalize patched to a fake
//     device (a valid-but-dumb device with every feature and huge limits), so
//     skipIfDeviceDoesHaveFeature-style guards behave;
//   - a no-op recorder (the framework's TestCaseRecorder);
//   - ShaderValidationTest.expectCompileResult / expectCompileWarning patched
//     to RECORD (code, expected) instead of compiling.
//
// Scope: src/webgpu/shader/validation only (the compile-focused half of
// webgpu:shader; the execution half measures GPU runtime behavior, which is
// outside a cross-compiler ingestion harness). Tests that iterate SUBCASES
// are counted and skipped (their shaders are assembled per-subcase batch in
// framework state we do not drive). A handful of cases error out (device
// paths not covered by the fake); they are counted, never silently dropped.
//
// Usage: node tools/webgpu_cts_dump.mjs <cts-js-out-dir> <dst-dump.json>
//        (also writes <dst-dump.json>.stats.json next to the dump)
import { readdirSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';

const OUT = process.argv[2];
const DST = process.argv[3];
if (!OUT || !DST) {
  console.error('usage: webgpu_cts_dump.mjs <cts-js-out-dir> <dst-dump.json>');
  process.exit(2);
}

const gpuTest = await import(join(OUT, 'webgpu/gpu_test.js'));
const GPUTestSubcaseBatchState = gpuTest.GPUTestSubcaseBatchState;

// --- patches: no GPU, no recorder -------------------------------------------
const fakeDevice = {
  features: { has: () => true, [Symbol.iterator]: function* () {} },
  limits: new Proxy({}, { get: () => 1e9 }),
  queue: {},
  destroy() {},
  createShaderModule() {
    return { getCompilationInfo: async () => ({ messages: [] }) };
  },
};
const fakeProvider = {
  device: fakeDevice,
  adapter: { features: fakeDevice.features, limits: fakeDevice.limits },
};
GPUTestSubcaseBatchState.prototype.acquireProvider = async () => fakeProvider;
GPUTestSubcaseBatchState.prototype.acquireMismatchedProvider = async () => fakeProvider;
GPUTestSubcaseBatchState.prototype.finalize = async function () {};

const noopRec = new Proxy({}, { get: () => () => {} });

// --- capture ----------------------------------------------------------------
const dumped = [];
const svt = await import(join(OUT, 'webgpu/shader/validation/shader_validation_test.js'));
const ShaderValidationTest = svt.ShaderValidationTest;
ShaderValidationTest.prototype.expectCompileResult = function (expected, code) {
  dumped.push({ file: this.__file, test: this.__test, params: this.params, expected: !!expected, code });
};
ShaderValidationTest.prototype.expectCompileWarning = function (expect, code) {
  dumped.push({ file: this.__file, test: this.__test, params: this.params, expected: true, code, warning: expect });
};

const stats = { cases: 0, ran: 0, skipped: 0, err: 0, subcases: 0, dumped: 0 };
const errors = [];

function* walk(dir) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) yield* walk(p);
    else if (e.name.endsWith('.spec.js')) yield p;
  }
}

for (const specPath of walk(join(OUT, 'webgpu/shader/validation'))) {
  const rel = relative(OUT, specPath);
  let mod;
  try {
    mod = await import(specPath);
  } catch (e) {
    errors.push('IMPORT ' + rel + ': ' + e.message);
    continue;
  }
  if (!mod.g) continue;
  for (const t of mod.g.iterate()) {
    for (const rc of t.iterate(null)) {
      stats.cases++;
      if (rc.subcases) {
        stats.subcases++;
        continue;
      }
      const { fixture, fn, params } = rc;
      const before = dumped.length;
      try {
        const sharedState = fixture.MakeSharedState
          ? fixture.MakeSharedState(noopRec, params)
          : undefined;
        const inst = new fixture(sharedState, noopRec, params);
        inst.__file = rel;
        inst.__test = t.testPath.join(':');
        await inst.init();
        await fn(inst);
        stats.ran++;
        stats.dumped += dumped.length - before;
      } catch (e) {
        stats.ran++;
        if (e && e.name === 'SkipTestCase') stats.skipped++;
        else {
          stats.err++;
          if (errors.length < 50) errors.push('RUN ' + rel + ' ' + t.testPath.join(':') + ': ' + (e && e.message));
        }
      }
    }
  }
}

writeFileSync(DST, JSON.stringify(dumped));
writeFileSync(DST + '.stats.json', JSON.stringify({ stats, errors }, null, 1));
console.log(JSON.stringify({ stats, first_errors: errors.slice(0, 8) }, null, 1));
// Fails closed: a dump that captured nothing means the patches missed.
if (stats.dumped === 0) {
  console.error('error: zero shaders dumped -- framework moved under the patches');
  process.exit(2);
}

import Metal
import Foundation

// Generic Metal COMPUTE differential harness.
//
// Given two MSL compute kernels for the same GLSL source, one produced by
// zioshade (GLSL -> MSL directly) and one by the reference toolchain
// (GLSL -> SPIR-V via glslang -> MSL via SPIRV-Cross), this runs BOTH on the
// Metal GPU over an identical input buffer and diffs the output buffers.
//
// It is the compute-shader analogue of ShaderCompare.swift (which diffs
// rendered framebuffers for fragment shaders). Where ShaderCompare proves
// pixel equivalence, this proves *numeric buffer* equivalence across the whole
// scalar/vector/matrix/intrinsic surface a compute kernel can touch.
//
// Both kernels must expose:
//   binding 0  ->  readonly  buffer { float inData[]; }   (Metal [[buffer(0)]])
//   binding 1  ->  writeonly buffer { float outData[]; }  (Metal [[buffer(1)]])
// and a `main0` entry point. zioshade and SPIRV-Cross both emit exactly this
// for the corpus in tools/compute_corpus/.
//
// Usage: ShaderComputeCompare <a.msl> <b.msl> [count]
// Exit 0 if the outputs match within tolerance, non-zero otherwise, so it
// doubles as a gate.

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: ShaderComputeCompare <a.msl> <b.msl> [count]")
    exit(2)
}
let pathA = args[1]
let pathB = args[2]
let N = args.count > 3 ? (Int(args[3]) ?? 1024) : 1024  // multiple of 64 => no OOB threads

guard let device = MTLCreateSystemDefaultDevice() else {
    print("ERROR: no Metal device"); exit(2)
}

func loadKernel(_ path: String) -> MTLComputePipelineState {
    do {
        let src = try String(contentsOfFile: path, encoding: .utf8)
        let lib = try device.makeLibrary(source: src, options: nil)
        guard let fn = lib.makeFunction(name: "main0") else {
            print("ERROR: no main0 in \(path) (have \(lib.functionNames))"); exit(3)
        }
        return try device.makeComputePipelineState(function: fn)
    } catch {
        print("ERROR compiling \(path): \(error)"); exit(3)
    }
}

// Deterministic, varied input spanning negatives, zero, positives and a
// fractional spread that exercises rounding. Range ~[-8.7, +8.7].
var input = [Float](repeating: 0, count: N)
for i in 0..<N { input[i] = (Float(i) - Float(N) / 2.0) * 0.017 }
let inBuf = device.makeBuffer(bytes: &input, length: N * 4, options: .storageModeShared)!

let queue = device.makeCommandQueue()!

func run(_ pipe: MTLComputePipelineState) -> [Float] {
    let outBuf = device.makeBuffer(length: N * 4, options: .storageModeShared)!
    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipe)
    enc.setBuffer(inBuf, offset: 0, index: 0)
    enc.setBuffer(outBuf, offset: 0, index: 1)
    let tpg = MTLSize(width: 64, height: 1, depth: 1)
    let groups = MTLSize(width: (N + 63) / 64, height: 1, depth: 1)
    enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tpg)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    var out = [Float](repeating: 0, count: N)
    memcpy(&out, outBuf.contents(), N * 4)
    return out
}

let a = run(loadKernel(pathA))
let b = run(loadKernel(pathB))

var maxAbs: Float = 0
var maxRel: Float = 0
var nDiff = 0
var nExact = 0
var nBothNaN = 0
var nNanMismatch = 0
for i in 0..<N {
    let x = a[i], y = b[i]
    if x.isNaN || y.isNaN {
        if x.isNaN && y.isNaN { nBothNaN += 1 } else { nNanMismatch += 1 }
        continue
    }
    let d = abs(x - y)
    if d == 0 { nExact += 1 } else { nDiff += 1 }
    maxAbs = max(maxAbs, d)
    let denom = max(abs(x), abs(y))
    if denom > 1e-6 { maxRel = max(maxRel, d / denom) }
}

print("""
count:            \(N)
exact-equal:      \(nExact)
differing:        \(nDiff)
both-NaN:         \(nBothNaN)
NaN-mismatch:     \(nNanMismatch)
max abs diff:     \(maxAbs)
max rel diff:     \(maxRel)
""")

// Tolerance: same math, same GPU, so bit-exact is common; allow a small
// relative slack for legitimate instruction-selection reordering. A NaN
// mismatch is always a failure (one side computed a number, the other didn't).
let ok = nNanMismatch == 0 && maxRel <= 1e-4
print(ok ? "MATCH" : "DIFFER")
exit(ok ? 0 : 1)

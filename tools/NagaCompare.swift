import Metal
import Foundation

// NagaCompare — second-oracle render differential (zioshade-MSL vs naga-MSL).
//
// Closes the correlated-error blind spot a single-oracle (SPIRV-Cross) differential
// cannot see: if zioshade and SPIRV-Cross shared a spec misreading, both would render
// identically-but-WRONG and pass silently. naga is an INDEPENDENT cross-compiler; where
// zioshade, spirv-cross, AND naga all render the same pixels, a shared misreading is far
// less likely → "render-proven-2-oracle". Where they disagree, there is no ground truth,
// so this tool only FLAGS (never claims a zioshade bug) — disagreements are logged for
// investigation, never auto-"fixed" (that would manufacture plausible-wrong).
//
// naga emits MSL in a different convention than spirv-cross: a plain `main_1(...)`
// function taking `thread` refs (no `main0`, no `main0_in` struct, no entry-point
// attributes). So we APPEND a generated Metal entry point that calls main_1, then render
// with the same fullscreen-triangle + read-pixels plumbing as ShaderCompare.swift.
//
// FIRST CUT: handles the common simple signature main_1(thread float4& pos, thread float4&
// color) — gl_FragCoord + a single color output, no uniforms/textures. Shaders with richer
// main_1 signatures are honest-skipped (skip-naga-complex), mirroring prove's skip model.
//
// Usage: NagaCompare <zioshade.msl> <naga.metal> [output_prefix]

func readMSL(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

// Does naga's main_1 have the simple 2-float4-ref signature (position + single color out)?
// Regex is intentionally narrow: exactly two `thread ... float4&` params and nothing else.
func nagaHasSimpleSig(_ msl: String) -> Bool {
    guard let r = msl.range(of: #"void main_1\(\s*thread\s+[A-Za-z0-9_:]*float4&\s*\w+,\s*thread\s+[A-Za-z0-9_:]*float4&\s*\w+\s*\)"#, options: .regularExpression) else {
        return false
    }
    // Reject if there's a third param (regex above already bounds to exactly 2 + close paren).
    return r != msl.startIndex..<msl.startIndex
}

// Append a Metal fragment entry that wires [[position]] → main_1's first param and a
// color out → its second param. Uses `using namespace metal` so `float4` resolves.
func wrapNagaEntry(_ msl: String) -> String {
    return msl + "\nusing namespace metal;\n" + """
fragment float4 naga_entry(float4 _pos [[position]]) {
    float4 _naga_out = 0.0;
    main_1(_pos, _naga_out);
    return _naga_out;
}
"""
}

func makeVertexLibrary(device: MTLDevice) -> MTLLibrary {
    let vertMSL = """
#include <metal_stdlib>
using namespace metal;
struct VertexOut { float4 position [[position]]; };
vertex VertexOut full_screen_vertex(uint vid [[vertex_id]]) {
    float4 pos;
    pos.x = (vid == 2) ? 3.0 : -1.0;
    pos.y = (vid == 0) ? -3.0 : 1.0;
    pos.zw = 1.0;
    VertexOut out = {};
    out.position = pos;
    return out;
}
"""
    return try! device.makeLibrary(source: vertMSL, options: nil)
}

func renderFrame(device: MTLDevice, vertLib: MTLLibrary, fragLib: MTLLibrary, w: Int, h: Int) -> [UInt8] {
    let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    outDesc.usage = [.renderTarget, .shaderRead]
    let outTexture = device.makeTexture(descriptor: outDesc)!
    let passDesc = MTLRenderPassDescriptor()
    passDesc.colorAttachments[0].texture = outTexture
    passDesc.colorAttachments[0].loadAction = .clear
    passDesc.colorAttachments[0].clearColor = MTLClearColor(red:0,green:0,blue:0,alpha:1)
    passDesc.colorAttachments[0].storeAction = .store
    let queue = device.makeCommandQueue()!
    let cmdBuf = queue.makeCommandBuffer()!
    let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
    let vertFunc = vertLib.makeFunction(name: "full_screen_vertex")
    var fragFunc: MTLFunction? = nil
    for name in ["main0", "naga_entry", "mainImage", "fragment_main0"] {
        if let f = fragLib.makeFunction(name: name) { fragFunc = f; break }
    }
    let pipeDesc = MTLRenderPipelineDescriptor()
    pipeDesc.vertexFunction = vertFunc
    pipeDesc.fragmentFunction = fragFunc
    pipeDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
    let pipeline = try! device.makeRenderPipelineState(descriptor: pipeDesc)
    encoder.setRenderPipelineState(pipeline)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    cmdBuf.commit()
    cmdBuf.waitUntilCompleted()
    var result = [UInt8](repeating: 0, count: w * h * 4)
    let region = MTLRegion(origin:.init(x:0,y:0,z:0), size:.init(width:w,height:h,depth:1))
    outTexture.getBytes(&result, bytesPerRow: w*4, from: region, mipmapLevel: 0)
    return result
}

func compareMax(_ a: [UInt8], _ b: [UInt8], count: Int) -> (maxDiff: Int, diffPixels: Int) {
    var maxD = 0, diffPx = 0
    var i = 0
    while i < count {
        var pixelDiff = false
        let end = min(i + 4, count)
        var j = i
        while j < end {
            let d = abs(Int(a[j]) - Int(b[j])); maxD = max(maxD, d)
            if d > 0 { pixelDiff = true }
            j += 1
        }
        if pixelDiff { diffPx += 1 }
        i += 4
    }
    return (maxD, diffPx)
}

// ---- Main ----
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: NagaCompare <zioshade.msl> <naga.metal> [output_prefix]")
    exit(1)
}
let zPath = args[1], nPath = args[2]
let prefix = args.count > 3 ? args[3] : "/tmp/naga_compare"
let envRes = ProcessInfo.processInfo.environment["SHADERCOMPARE_RES"]
let W: Int = Int(envRes ?? "64") ?? 64
let H: Int = W

let zMSL = try readMSL(zPath)
let nRaw = try readMSL(nPath)
guard nagaHasSimpleSig(nRaw) else {
    print("skip-naga-complex"); exit(0)
}
let nMSL = wrapNagaEntry(nRaw)

guard let device = MTLCreateSystemDefaultDevice() else { print("ERROR: No Metal device"); exit(1) }
let vertLib = makeVertexLibrary(device: device)

let libZ = try device.makeLibrary(source: zMSL, options: nil)
let libN = try device.makeLibrary(source: nMSL, options: nil)

let pz = renderFrame(device: device, vertLib: vertLib, fragLib: libZ, w: W, h: H)
let pn = renderFrame(device: device, vertLib: vertLib, fragLib: libN, w: W, h: H)

let r = compareMax(pz, pn, count: W*H*4)
print("""
=== NagaCompare (2nd oracle) ===
Resolution: \(W)x\(H)  Pixels: \(W*H)  Different: \(r.diffPixels)
Max channel diff: \(r.maxDiff)
\(r.maxDiff <= 1 ? "MATCH (zioshade == naga; 2-oracle agreement on this shader)" : "DIFFER (no ground truth — flag for investigation, NOT a proven zioshade bug)")
""")

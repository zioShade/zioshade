import Metal
import Foundation

// NagaCompare — second-oracle render differential (zioshade-MSL vs naga-MSL).
//
// Closes the correlated-error blind spot a single-oracle (SPIRV-Cross) differential
// cannot see: if zioshade and SPIRV-Cross shared a spec misreading, both would render
// identically-but-WRONG and pass silently. naga is an INDEPENDENT cross-compiler; where
// zioshade, spirv-cross, AND naga all render the same pixels, a shared misreading is far
// less likely → "render-proven-2-oracle". MSL is wintty's shipping backend.
//
// HARD RULE (per the deciding panel, mitigating the devil's-advocate risk): value is in
// AGREEMENT, not disagreement. A DIFFER has no ground truth — it is FLAGGED for
// investigation, NEVER auto-"fixed" (that would manufacture plausible-wrong).
//
// naga emits a COMPLETE renderable MSL: a `main_` fragment entry point plus `main_Input` /
// `main_Output` structs with proper [[stage_in]] / [[user(locN)]] / [[color(N)]] attributes
// (spirv-cross uses `main0` / `main0_in` / `main0_out` instead). So we render naga's native
// `main_` directly — no generated wrapper — building a fullscreen-triangle vertex whose
// output struct mirrors the fragment's stage_in struct (zero-initialised varyings), the
// same trick ShaderCompare.swift uses for main0_in. Both sides get the SAME (zero) varyings,
// so the pixel differential stays valid.
//
// Coverage: shaders whose interface is varyings + color out (no uniforms/textures) render
// unaided. Shaders needing buffer/texture bindings skip-render (mirrors prove's skip model).
//
// Usage: NagaCompare <zioshade.msl> <naga.metal> [output_prefix]

func readMSL(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

// Body of a MSL `struct <name> { ... }` (between the braces), or "" if absent.
func structBody(_ msl: String, _ name: String) -> String {
    guard let r = msl.range(of: "struct \(name)") else { return "" }
    let after = msl[r.upperBound...]
    guard let ob = after.firstIndex(of: "{"),
          let cb = after[after.index(after: ob)...].firstIndex(of: "}") else { return "" }
    return String(after[after.index(after: ob)..<cb])
}

// spirv-cross/zioshade use main0_in; naga uses main_Input. "" if the fragment has no varyings.
func stageInStruct(_ msl: String) -> String {
    if msl.contains("struct main0_in") { return "main0_in" }
    if msl.contains("struct main_Input") { return "main_Input" }
    return ""
}

func makeVertexLibrary(device: MTLDevice, stageInStructName: String, fragmentMSL: String) -> MTLLibrary {
    let members = structBody(fragmentMSL, stageInStructName)
    let vertMSL = """
#include <metal_stdlib>
using namespace metal;
struct VertexOut { float4 position [[position]];
\(members)
};
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
    for name in ["main0", "main_", "mainImage", "fragment_main0"] {
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
        let end = min(i + 4, count); var j = i
        while j < end { let d = abs(Int(a[j]) - Int(b[j])); maxD = max(maxD, d); if d > 0 { pixelDiff = true }; j += 1 }
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
let nMSL = try readMSL(nPath)

guard let device = MTLCreateSystemDefaultDevice() else { print("ERROR: No Metal device"); exit(1) }
let vertLibZ = makeVertexLibrary(device: device, stageInStructName: stageInStruct(zMSL), fragmentMSL: zMSL)
let vertLibN = makeVertexLibrary(device: device, stageInStructName: stageInStruct(nMSL), fragmentMSL: nMSL)

let libZ = try device.makeLibrary(source: zMSL, options: nil)
let libN = try device.makeLibrary(source: nMSL, options: nil)

let pz = renderFrame(device: device, vertLib: vertLibZ, fragLib: libZ, w: W, h: H)
let pn = renderFrame(device: device, vertLib: vertLibN, fragLib: libN, w: W, h: H)

let r = compareMax(pz, pn, count: W*H*4)
print("""
=== NagaCompare (2nd oracle) ===
Resolution: \(W)x\(H)  Pixels: \(W*H)  Different: \(r.diffPixels)
Max channel diff: \(r.maxDiff)
\(r.maxDiff <= 1 ? "MATCH (zioshade == naga; 2-oracle agreement on this shader)" : "DIFFER (no ground truth — flag for investigation, NOT a proven zioshade bug)")
""")

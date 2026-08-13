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
// Coverage: shaders whose interface is varyings + color out render unaided; uniform/texture-
// bound shaders get DETERMINISTIC bindings via pipeline reflection (bindDeterministicInputs):
// each [[buffer(N)]] receives a fixed tame pattern, each [[texture(N)]] a fixed generated
// image, each sampler a fixed state -- the SAME objects on both sides, so the pixel
// differential stays valid for bound shaders too (same inputs -> different pixels means
// different semantics). The synthetic pattern can still surface layout disagreements (a
// genuine bug class: one backend mis-laying-out a UBO reads different bytes) -- triage by
// hand per the HARD RULE above.
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
    // Varying-less fragments (e.g. gl_FragCoord only) have no stage_in struct; copy no
    // members. Guarding the empty name avoids structBody matching "struct " and pulling in
    // the fragment OUTPUT struct (e.g. main0_out's [[color(0)]] member) — which is an
    // invalid vertex output and crashed every varying-less shader into skip-render.
    let membersRaw = stageInStructName.isEmpty ? "" : structBody(fragmentMSL, stageInStructName)
    // A varying NAMED `position` collides with VertexOut's own `position [[position]]`
    // member (duplicate-member compile error -> every such shader skip-rendered, e.g.
    // ubo-mvp.frag). RENAME it (the [[user(locN)]] attribute is what links it to the
    // fragment, not the member name); it stays zero-initialised like every other copied
    // varying. Member syntax is `<type> <name> [[attr]];`.
    let posMember = try! NSRegularExpression(pattern: #"position\s*\[\["#)
    let ms = NSMutableString(string: membersRaw)
    posMember.replaceMatches(in: ms, range: NSRange(location: 0, length: ms.length), withTemplate: "v_position [[")
    let members = ms as String
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

// Deterministic binding inputs, shared bit-identically between both renders so a pixel
// difference can only come from shader semantics. Buffers are filled with tame small
// positive floats (avoid NaN/inf chaos); textures with a fixed 8x8 pattern.
final class DeterministicInputs {
    let device: MTLDevice
    var buffers: [Int: MTLBuffer] = [:]
    var texture: MTLTexture? = nil
    var sampler: MTLSamplerState? = nil
    init(device: MTLDevice) { self.device = device }

    func bytes(for index: Int, count: Int) -> [UInt8] {
        // LCG per binding index; values in (0.01, ~0.77] as float32, small ints for any
        // integer-typed members land in the low bytes (also tame).
        var state: UInt32 = 0xC0FFEE00 &+ UInt32(truncatingIfNeeded: index &* 2654435761)
        var out = [UInt8](repeating: 0, count: count)
        var i = 0
        while i + 4 <= count {
            state = state &* 1664525 &+ 1013904223
            let v = Float(state % 97) / 128.0 + 0.01
            let bits = v.bitPattern
            out[i] = UInt8(truncatingIfNeeded: bits); out[i+1] = UInt8(truncatingIfNeeded: bits >> 8)
            out[i+2] = UInt8(truncatingIfNeeded: bits >> 16); out[i+3] = UInt8(truncatingIfNeeded: bits >> 24)
            i += 4
        }
        return out
    }

    func buffer(index: Int, size: Int) -> MTLBuffer {
        if let b = buffers[index] { return b }
        let n = max(size, 16)
        let data = bytes(for: index, count: n)
        let b = data.withUnsafeBytes { ptr -> MTLBuffer in
            device.makeBuffer(bytes: ptr.baseAddress!, length: n, options: [])!
        }
        buffers[index] = b
        return b
    }

    func sharedTexture() -> MTLTexture {
        if let t = texture { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        d.usage = [.shaderRead]
        let t = device.makeTexture(descriptor: d)!
        var px = [UInt8](repeating: 0, count: 8*8*4)
        for y in 0..<8 { for x in 0..<8 {
            let o = (y*8+x)*4
            px[o] = UInt8(x*32); px[o+1] = UInt8(y*32); px[o+2] = UInt8((x^y)*16+64); px[o+3] = 255
        }}
        px.withUnsafeBytes { ptr in t.replace(region: MTLRegionMake2D(0,0,8,8), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: 8*4) }
        texture = t
        return t
    }

    func sharedSampler() -> MTLSamplerState {
        if let s = sampler { return s }
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.sAddressMode = .repeat; d.tAddressMode = .repeat
        let s = device.makeSamplerState(descriptor: d)!
        sampler = s
        return s
    }
}

// Reflect the built pipeline's fragment arguments and bind a deterministic input to each
// (buffer/texture/sampler). Without this, bound shaders read unbound garbage.
func bindDeterministicInputs(encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, reflection: MTLRenderPipelineReflection?, inputs: DeterministicInputs) {
    guard let args = reflection?.fragmentArguments else { return }
    for a in args where a.isActive {
        switch a.type {
        case .buffer:
            encoder.setFragmentBuffer(inputs.buffer(index: a.index, size: a.bufferDataSize), offset: 0, index: a.index)
        case .texture:
            encoder.setFragmentTexture(inputs.sharedTexture(), index: a.index)
        case .sampler:
            encoder.setFragmentSamplerState(inputs.sharedSampler(), index: a.index)
        default:
            break
        }
    }
}

func renderFrame(device: MTLDevice, vertLib: MTLLibrary, fragLib: MTLLibrary, w: Int, h: Int, inputs: DeterministicInputs) -> [UInt8] {
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
    var refl: MTLRenderPipelineReflection? = nil
    let pipeline = try! device.makeRenderPipelineState(descriptor: pipeDesc, options: [.argumentInfo], reflection: &refl)
    encoder.setRenderPipelineState(pipeline)
    bindDeterministicInputs(encoder: encoder, pipeline: pipeline, reflection: refl, inputs: inputs)
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

// Opt-in precise-fp mode (SHADERCOMPARE_SAFE_MATH=1): compile both with Metal fast-math
// disabled, so only a genuine structural difference (not FP-contraction rounding at a
// discontinuity) can diverge. Used to triage a default-fast-math DIFFER as benign FP
// (becomes MATCH) vs structural (persists) — mirrors ShaderCompare / prove_opt.
let compileOpts: MTLCompileOptions? = {
    guard ProcessInfo.processInfo.environment["SHADERCOMPARE_SAFE_MATH"] == "1" else { return nil }
    let o = MTLCompileOptions(); o.mathMode = .safe; return o
}()

guard let device = MTLCreateSystemDefaultDevice() else { print("ERROR: No Metal device"); exit(1) }
let vertLibZ = makeVertexLibrary(device: device, stageInStructName: stageInStruct(zMSL), fragmentMSL: zMSL)
let vertLibN = makeVertexLibrary(device: device, stageInStructName: stageInStruct(nMSL), fragmentMSL: nMSL)

let libZ = try device.makeLibrary(source: zMSL, options: compileOpts)
let libN = try device.makeLibrary(source: nMSL, options: compileOpts)

// Shared deterministic binding inputs: the SAME buffer/texture/sampler objects go to both
// renders, so any pixel difference is semantics, not inputs.
let inputs = DeterministicInputs(device: device)

let pz = renderFrame(device: device, vertLib: vertLibZ, fragLib: libZ, w: W, h: H, inputs: inputs)
let pn = renderFrame(device: device, vertLib: vertLibN, fragLib: libN, w: W, h: H, inputs: inputs)

let r = compareMax(pz, pn, count: W*H*4)
print("""
=== NagaCompare (2nd oracle) ===
Resolution: \(W)x\(H)  Pixels: \(W*H)  Different: \(r.diffPixels)
Max channel diff: \(r.maxDiff)
\(r.maxDiff <= 1 ? "MATCH (zioshade == naga; 2-oracle agreement on this shader)" : "DIFFER (no ground truth — flag for investigation, NOT a proven zioshade bug)")
""")

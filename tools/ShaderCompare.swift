import Metal
import Foundation

// Generate a fullscreen-triangle vertex shader that WRITES every stage-input varying
// the fragment declares (zero-initialised), so fragments that read [[user(locnN)]]
// varyings render instead of failing "not written by vertex shader". The fragment's
// `main0_in` struct (spirv-cross's stage_in type) is copied verbatim into VertexOut --
// same [[user(locnN)]] attributes + types -- so the vertex output matches the fragment
// input exactly. Both zioshade + spirv-cross fragments get the SAME (zero) varyings, so
// the pixel differential stays a valid frontend check. (#render-coverage)
func makeVertexLibrary(device: MTLDevice, fragmentMSL: String) -> MTLLibrary {
    var members = ""
    if let r = fragmentMSL.range(of: "struct main0_in") {
        let after = fragmentMSL[r.upperBound...]
        if let openBrace = after.firstIndex(of: "{"),
           let closeBrace = after[after.index(after: openBrace)...].firstIndex(of: "}") {
            members = String(after[after.index(after: openBrace)..<closeBrace])
        }
    }
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

// Read MSL source from file
func readMSL(_ path: String) throws -> String {
    return try String(contentsOfFile: path, encoding: .utf8)
}

// Create a test texture (gradient + XOR pattern for iChannel0)
func createTestTexture(device: MTLDevice, w: Int, h: Int) -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.shaderRead]
    let texture = device.makeTexture(descriptor: desc)!
    let region = MTLRegion(origin: .init(x:0,y:0,z:0), size: .init(width:w,height:h,depth:1))
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        pixels[i+0] = UInt8(x * 255 / w)
        pixels[i+1] = UInt8(y * 255 / h)
        pixels[i+2] = UInt8((x ^ y) & 0xFF)
        pixels[i+3] = 255
    }}
    texture.replace(region:region, mipmapLevel:0, withBytes:pixels, bytesPerRow:w*4)
    return texture
}

// Globals buffer — now that zioshade struct layout matches spirv-cross
// (float4[4] for iChannelTime, float3[4] for iChannelResolution),
// a single buffer works for both.
func makeGlobalsBuffer(device: MTLDevice, screenW: Int, screenH: Int) -> MTLBuffer {
    let size = 4492
    var data = [UInt8](repeating: 0, count: size)
    data.withUnsafeMutableBytes { ptr in
        let f = ptr.bindMemory(to: Float.self)
        f[0] = Float(screenW)   // resolution.x (packed_float3, offset 0)
        f[1] = Float(screenH)   // resolution.y
        f[2] = 1.0              // resolution.z
        f[3] = 0.5              // time (offset 12)
        f[4] = 1.0/60.0         // time_delta (offset 16)
        f[5] = 60.0             // frame_rate (offset 20)
        let i32 = ptr.bindMemory(to: Int32.self)
        i32[6] = 1              // frame (offset 24)
        // iChannelTime float4[4] at offset 32: zeros
        // iChannelResolution float3[4] at offset 96: zeros
        // iMouse float4 at offset 160
        f[40] = 128.0  // mouse.x
        f[41] = 128.0  // mouse.y
    }
    return device.makeBuffer(bytes: data, length: size)!
}

func renderFrame(device: MTLDevice, vertLib: MTLLibrary, fragLib: MTLLibrary, texture: MTLTexture,
                 globalsBuf: MTLBuffer, w: Int, h: Int) -> [UInt8] {
    let outDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
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

    // Fragment: try known names
    var fragFunc: MTLFunction? = nil
    for name in ["main0", "mainImage", "fragment_main0"] {
        if let f = fragLib.makeFunction(name: name) { fragFunc = f; break }
    }

    let pipeDesc = MTLRenderPipelineDescriptor()
    pipeDesc.vertexFunction = vertFunc
    pipeDesc.fragmentFunction = fragFunc
    pipeDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
    let pipeline = try! device.makeRenderPipelineState(descriptor: pipeDesc)

    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(texture, index: 0)

    let sampDesc = MTLSamplerDescriptor()
    sampDesc.minFilter = .linear; sampDesc.magFilter = .linear
    encoder.setFragmentSamplerState(device.makeSamplerState(descriptor: sampDesc)!, index: 0)

    encoder.setFragmentBuffer(globalsBuf, offset: 0, index: 0)
    encoder.setFragmentBuffer(globalsBuf, offset: 0, index: 1)  // zioshade uses binding=1 from wintty shaders
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    cmdBuf.commit()
    cmdBuf.waitUntilCompleted()

    var result = [UInt8](repeating: 0, count: w * h * 4)
    let region = MTLRegion(origin:.init(x:0,y:0,z:0), size:.init(width:w,height:h,depth:1))
    outTexture.getBytes(&result, bytesPerRow: w*4, from: region, mipmapLevel: 0)
    return result
}

func comparePixels(_ a: [UInt8], _ b: [UInt8], count: Int) -> (maxDiff: Int, avgDiff: Float, diffPixels: Int) {
    var maxD = 0, totalD = 0, diffPx = 0
    var i = 0
    while i < count {
        // A pixel counts as different if ANY of its RGBA channels differ -- the old
        // `i % 4 == 0` test only looked at the red channel, so a shader wrong only in
        // green/blue/alpha reported 0 differing pixels while maxDiff was 255 (it masked
        // the severity of a real miscompile, e.g. for-loop-continue rendering all-black).
        var pixelDiff = false
        let end = min(i + 4, count)
        var j = i
        while j < end {
            let d = abs(Int(a[j]) - Int(b[j]))
            maxD = max(maxD, d)
            totalD += d
            if d > 0 { pixelDiff = true }
            j += 1
        }
        if pixelDiff { diffPx += 1 }
        i += 4
    }
    return (maxD, Float(totalD) / Float(count), diffPx)
}

// Classify a DIFFER as a benign measure-zero FP-boundary artifact vs a real
// miscompile. A genuine logic bug affects a REGION of input space (its pixel
// count scales with resolution); a floating-point rounding flip at a
// discontinuity (escape-time fractals, step()/smoothstep/fwidth edges) affects a
// measure-zero set of pixels that sit in high-variance (textured/edge)
// neighborhoods. Heuristic, validated by multi-resolution proof on mandelbrot3
// (1->3->3 differing pixels across 256/512/1024 — measure-zero, not a region)
// plus a 5-voice panel. Returns true = suspected benign boundary (label only;
// not silent acceptance — the caller logs it as EDGE(boundary) for audit).
// Discriminator is LOCAL VARIANCE: a lone diff in a FLAT region stays a real
// DIFFER (suspicious); a diff in a chaotic region is consistent with an FP edge.
func classifyBoundaryDiff(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int, diffPixels: Int) -> Bool {
    // Few differing pixels: < 0.05% of the image. A region bug would be far more.
    if diffPixels == 0 || diffPixels > max(8, (w * h) / 2000) { return false }
    var stdSum = 0.0
    var n = 0
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        var pixelDiff = false
        for c in 0..<3 { if a[i + c] != b[i + c] { pixelDiff = true; break } }
        if !pixelDiff { continue }
        // 5x5 luma neighborhood in render `a`.
        var vals: [Double] = []
        for dy in -2...2 { for dx in -2...2 {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
            let j = (ny * w + nx) * 4
            let luma = 0.3*Double(a[j]) + 0.59*Double(a[j+1]) + 0.11*Double(a[j+2])
            vals.append(luma)
        }}
        if vals.count < 6 { continue }
        let mean = vals.reduce(0, +) / Double(vals.count)
        let variance = vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count)
        stdSum += variance.squareRoot()
        n += 1
    }}
    if n == 0 { return false }
    let meanStd = stdSum / Double(n)
    // std > ~15 luma units => textured/edge => consistent with an FP boundary.
    // (mandelbrot3 differing pixels measure ~50-70; a flat-region diff ~0.)
    return meanStd > 15.0
}

func savePPM(_ px: [UInt8], w: Int, h: Int, path: String) throws {
    var s = "P3\n\(w) \(h)\n255\n"
    for y in 0..<h {
        var row = [String]()
        for x in 0..<w {
            let i = (y*w+x)*4
            row.append("\(px[i]) \(px[i+1]) \(px[i+2])")
        }
        s += row.joined(separator:" ") + "\n"
    }
    try s.write(toFile: path, atomically: true, encoding: .ascii)
}

// ---- Main ----
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: ShaderCompare <zioshade.msl> <spirvcross.msl> [output_prefix]")
    exit(1)
}

let zioshadePath = args[1]
let spirvcrossPath = args[2]
let prefix = args.count > 3 ? args[3] : "/tmp/shader_compare"
// Resolution env-gated for boundary-vs-bug verification (default unchanged).
let envRes = ProcessInfo.processInfo.environment["SHADERCOMPARE_RES"]
let W: Int = Int(envRes ?? "256") ?? 256
let H: Int = W

guard let device = MTLCreateSystemDefaultDevice() else {
    print("ERROR: No Metal device"); exit(1)
}
print("Metal: \(device.name)")

let msl1 = try readMSL(zioshadePath)
let msl2 = try readMSL(spirvcrossPath)

// Opt-in precise-fp mode (default off, so the shipping-path render check is unchanged).
// When SHADERCOMPARE_SAFE_MATH=1, compile both shaders with Metal fast-math disabled
// (mathMode = .safe). The frontend oracle uses this to re-check a suspected miscompile:
// with fast-math on, two semantically-equivalent SPIR-Vs can round differently at an fp
// discontinuity (e.g. a step() edge on a pixel center) because Metal's contraction is
// context-sensitive to the full MSL text; disabling it cancels that so only a genuine
// structural frontend difference (e.g. reading uninitialized memory) can still diverge.
let compileOpts: MTLCompileOptions? = {
    guard ProcessInfo.processInfo.environment["SHADERCOMPARE_SAFE_MATH"] == "1" else { return nil }
    let o = MTLCompileOptions()
    o.mathMode = .safe
    return o
}()
if compileOpts != nil { print("Precise-fp mode: Metal fast-math disabled (mathMode=.safe)") }

let vertLib = makeVertexLibrary(device: device, fragmentMSL: msl1)

print("Compiling zioshade MSL (\(msl1.count) bytes)...")
let lib1 = try device.makeLibrary(source: msl1, options: compileOpts)
print("  Functions: \(lib1.functionNames)")

print("Compiling spirv-cross MSL (\(msl2.count) bytes)...")
let lib2 = try device.makeLibrary(source: msl2, options: compileOpts)
print("  Functions: \(lib2.functionNames)")

let texture = createTestTexture(device: device, w: W, h: H)
let globals = makeGlobalsBuffer(device: device, screenW: W, screenH: H)

print("Rendering zioshade...")
let px1 = renderFrame(device: device, vertLib: vertLib, fragLib: lib1, texture: texture, globalsBuf: globals, w: W, h: H)

print("Rendering spirv-cross...")
let px2 = renderFrame(device: device, vertLib: vertLib, fragLib: lib2, texture: texture, globalsBuf: globals, w: W, h: H)

try savePPM(px1, w: W, h: H, path: "\(prefix)_zioshade.ppm")
try savePPM(px2, w: W, h: H, path: "\(prefix)_spirvcross.ppm")

let r = comparePixels(px1, px2, count: W*H*4)
print("""
=== Results ===
Resolution: \(W)x\(H)
Pixels: \(W*H)  Different: \(r.diffPixels)
Max channel diff: \(r.maxDiff)
Avg channel diff: \(String(format:"%.4f", r.avgDiff))
\(r.maxDiff <= 1 ? "MATCH (<=1 per-channel)" : (classifyBoundaryDiff(px1, px2, w: W, h: H, diffPixels: r.diffPixels) ? "DIFFER_BOUNDARY (max diff: \(r.maxDiff))" : "DIFFER (max diff: \(r.maxDiff))"))
""")

// Diff image (amplified)
var diffPx = [UInt8](repeating: 0, count: W*H*4)
for i in 0..<W*H {
    let j = i*4
    let d = max(abs(Int(px1[j])-Int(px2[j])),
                abs(Int(px1[j+1])-Int(px2[j+1])),
                abs(Int(px1[j+2])-Int(px2[j+2])))
    let s = min(d * 10, 255)
    diffPx[j] = UInt8(s); diffPx[j+2] = UInt8(s); diffPx[j+3] = 255
}
try savePPM(diffPx, w: W, h: H, path: "\(prefix)_diff.ppm")
print("Saved: \(prefix)_zioshade.ppm  \(prefix)_spirvcross.ppm  \(prefix)_diff.ppm")

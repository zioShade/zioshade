import Metal
import Foundation

// Simple fullscreen triangle vertex shader - embedded as MSL string
let vertexMSL = """
#include <metal_stdlib>
using namespace metal;
struct VertexOut { float4 position [[position]]; };
vertex VertexOut full_screen_vertex(uint vid [[vertex_id]]) {
    float4 pos;
    pos.x = (vid == 2) ? 3.0 : -1.0;
    pos.y = (vid == 0) ? -3.0 : 1.0;
    pos.zw = 1.0;
    VertexOut out; out.position = pos; return out;
}
"""

func makeVertexLibrary(device: MTLDevice) -> MTLLibrary {
    return try! device.makeLibrary(source: vertexMSL, options: nil)
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

// Globals buffer — uses packed_float3 layout (12 bytes), matching both
// spirv-cross and glslpp (now fixed to emit packed_float3).
func makeGlobalsBuffer(device: MTLDevice, screenW: Int, screenH: Int) -> MTLBuffer {
    let size = 4492
    var data = [UInt8](repeating: 0, count: size)
    data.withUnsafeMutableBytes { ptr in
        let f = ptr.bindMemory(to: Float.self)
        f[0] = Float(screenW)   // resolution.x
        f[1] = Float(screenH)   // resolution.y
        f[2] = 1.0              // resolution.z
        f[3] = 0.5              // time
        f[4] = 1.0/60.0         // time_delta
        f[5] = 60.0             // frame_rate
        let i32 = ptr.bindMemory(to: Int32.self)
        i32[6] = 1              // frame
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

    encoder.setFragmentBuffer(globalsBuf, offset: 0, index: 1)
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
    for i in 0..<count {
        let d = abs(Int(a[i]) - Int(b[i]))
        maxD = max(maxD, d)
        totalD += d
        if d > 0 && i % 4 == 0 { diffPx += 1 }
    }
    return (maxD, Float(totalD) / Float(count), diffPx)
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
    print("Usage: ShaderCompare <glslpp.msl> <spirvcross.msl> [output_prefix]")
    exit(1)
}

let glslppPath = args[1]
let spirvcrossPath = args[2]
let prefix = args.count > 3 ? args[3] : "/tmp/shader_compare"
let W = 256, H = 256

guard let device = MTLCreateSystemDefaultDevice() else {
    print("ERROR: No Metal device"); exit(1)
}
print("Metal: \(device.name)")

let msl1 = try readMSL(glslppPath)
let msl2 = try readMSL(spirvcrossPath)

let vertLib = makeVertexLibrary(device: device)

print("Compiling glslpp MSL (\(msl1.count) bytes)...")
let lib1 = try device.makeLibrary(source: msl1, options: nil)
print("  Functions: \(lib1.functionNames)")

print("Compiling spirv-cross MSL (\(msl2.count) bytes)...")
let lib2 = try device.makeLibrary(source: msl2, options: nil)
print("  Functions: \(lib2.functionNames)")

let texture = createTestTexture(device: device, w: W, h: H)
let globals = makeGlobalsBuffer(device: device, screenW: W, screenH: H)

print("Rendering glslpp...")
let px1 = renderFrame(device: device, vertLib: vertLib, fragLib: lib1, texture: texture, globalsBuf: globals, w: W, h: H)

print("Rendering spirv-cross...")
let px2 = renderFrame(device: device, vertLib: vertLib, fragLib: lib2, texture: texture, globalsBuf: globals, w: W, h: H)

try savePPM(px1, w: W, h: H, path: "\(prefix)_glslpp.ppm")
try savePPM(px2, w: W, h: H, path: "\(prefix)_spirvcross.ppm")

let r = comparePixels(px1, px2, count: W*H*4)
print("""
=== Results ===
Resolution: \(W)x\(H)
Pixels: \(W*H)  Different: \(r.diffPixels)
Max channel diff: \(r.maxDiff)
Avg channel diff: \(String(format:"%.4f", r.avgDiff))
\(r.maxDiff <= 1 ? "MATCH (<=1 per-channel)" : "DIFFER (max diff: \(r.maxDiff))")
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
print("Saved: \(prefix)_glslpp.ppm  \(prefix)_spirvcross.ppm  \(prefix)_diff.ppm")

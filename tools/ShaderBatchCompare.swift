import Metal
import Foundation

// Simple fullscreen triangle vertex shader
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

// Generic uniform buffer for shaders that just need resolution
func makeSimpleUniformBuffer(device: MTLDevice, w: Int, h: Int) -> MTLBuffer {
    // 16 bytes: float2 resolution, float2 pad
    var data = [Float](repeating: 0, count: 4)
    data[0] = Float(w)
    data[1] = Float(h)
    return device.makeBuffer(bytes: &data, length: 16)!
}

// Wintty Globals buffer (4492 bytes)
func makeWinttyGlobalsBuffer(device: MTLDevice, screenW: Int, screenH: Int) -> MTLBuffer {
    let size = 4492
    var data = [UInt8](repeating: 0, count: size)
    data.withUnsafeMutableBytes { ptr in
        let f = ptr.bindMemory(to: Float.self)
        f[0] = Float(screenW); f[1] = Float(screenH); f[2] = 1.0
        f[3] = 0.5  // time
        f[40] = 128.0; f[41] = 128.0  // mouse
    }
    return device.makeBuffer(bytes: data, length: size)!
}

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

func renderShader(device: MTLDevice, vertLib: MTLLibrary, fragLib: MTLLibrary, 
                  texture: MTLTexture, uniformBuf: MTLBuffer, w: Int, h: Int) -> [UInt8]? {
    let outDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    outDesc.usage = [.renderTarget, .shaderRead]
    guard let outTexture = device.makeTexture(descriptor: outDesc) else { return nil }

    let passDesc = MTLRenderPassDescriptor()
    passDesc.colorAttachments[0].texture = outTexture
    passDesc.colorAttachments[0].loadAction = .clear
    passDesc.colorAttachments[0].clearColor = MTLClearColor(red:0,green:0,blue:0,alpha:1)
    passDesc.colorAttachments[0].storeAction = .store

    guard let queue = device.makeCommandQueue(),
          let cmdBuf = queue.makeCommandBuffer(),
          let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { return nil }

    let vertFunc = vertLib.makeFunction(name: "full_screen_vertex")

    // Try known entry point names
    var fragFunc: MTLFunction? = nil
    for name in ["main0", "mainImage", "fragment_main0", "main"] {
        if let f = fragLib.makeFunction(name: name) { fragFunc = f; break }
    }
    guard let vf = vertFunc, let ff = fragFunc else { return nil }

    let pipeDesc = MTLRenderPipelineDescriptor()
    pipeDesc.vertexFunction = vf
    pipeDesc.fragmentFunction = ff
    pipeDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipeDesc) else { return nil }

    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(texture, index: 0)
    let sampDesc = MTLSamplerDescriptor()
    sampDesc.minFilter = .linear; sampDesc.magFilter = .linear
    encoder.setFragmentSamplerState(device.makeSamplerState(descriptor: sampDesc)!, index: 0)
    encoder.setFragmentBuffer(uniformBuf, offset: 0, index: 0)
    encoder.setFragmentBuffer(uniformBuf, offset: 0, index: 1)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    cmdBuf.commit()
    cmdBuf.waitUntilCompleted()

    var result = [UInt8](repeating: 0, count: w * h * 4)
    let region = MTLRegion(origin:.init(x:0,y:0,z:0), size:.init(width:w,height:h,depth:1))
    outTexture.getBytes(&result, bytesPerRow: w*4, from: region, mipmapLevel: 0)
    return result
}

func countNonBlack(_ px: [UInt8], w: Int, h: Int) -> Int {
    var count = 0
    for i in 0..<(w*h) {
        let j = i*4
        if px[j] > 0 || px[j+1] > 0 || px[j+2] > 0 { count += 1 }
    }
    return count
}

func comparePixels(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int) -> (maxDiff: Int, avgDiff: Float, diffPixels: Int) {
    let totalChannels = w * h * 4
    var maxD = 0, totalD = 0, diffPx = 0
    for i in 0..<totalChannels {
        let d = abs(Int(a[i]) - Int(b[i]))
        maxD = max(maxD, d)
        totalD += d
    }
    // Count different pixels (any channel differs)
    for i in 0..<(w*h) {
        let j = i*4
        if a[j] != b[j] || a[j+1] != b[j+1] || a[j+2] != b[j+2] { diffPx += 1 }
    }
    return (maxD, Float(totalD) / Float(totalChannels), diffPx)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("""
    Usage: ShaderBatchCompare <mode> [args...]
    
    Modes:
      pair <glslpp.msl> <spirvcross.msl> [prefix]
        Compare two MSL files side-by-side
      
      list <file_with_shader_pairs>
        Batch compare from a list of shader pair paths
        Format: <glslpp.msl> <spirvcross.msl> per line
    """)
    exit(1)
}

let mode = args[1]
let W = 256, H = 256

guard let device = MTLCreateSystemDefaultDevice() else {
    print("ERROR: No Metal device"); exit(1)
}
print("Metal: \(device.name)")

let vertLib = try! device.makeLibrary(source: vertexMSL, options: nil)
let texture = createTestTexture(device: device, w: W, h: H)

// Detect which uniform buffer to use based on shader source
func makeUniformBuffer(device: MTLDevice, glslppMSL: String, w: Int, h: Int) -> MTLBuffer {
    if glslppMSL.contains("Globals_m0") || glslppMSL.contains("iResolution") {
        return makeWinttyGlobalsBuffer(device: device, screenW: w, screenH: h)
    }
    return makeSimpleUniformBuffer(device: device, w: w, h: h)
}

func comparePair(device: MTLDevice, vertLib: MTLLibrary, texture: MTLTexture,
                 glslppPath: String, spirvcrossPath: String, prefix: String) -> Bool {
    do {
        let msl1 = try String(contentsOfFile: glslppPath, encoding: .utf8)
        let msl2 = try String(contentsOfFile: spirvcrossPath, encoding: .utf8)
        
        print("\n--- \(glslppPath) vs \(spirvcrossPath) ---")
        
        // Compile
        guard let lib1 = try? device.makeLibrary(source: msl1, options: nil) else {
            print("  SKIP: glslpp MSL failed to compile"); return false
        }
        guard let lib2 = try? device.makeLibrary(source: msl2, options: nil) else {
            print("  SKIP: spirv-cross MSL failed to compile"); return false
        }
        
        let uniformBuf = makeUniformBuffer(device: device, glslppMSL: msl1, w: W, h: H)
        
        // Render
        guard let px1 = renderShader(device: device, vertLib: vertLib, fragLib: lib1,
                                     texture: texture, uniformBuf: uniformBuf, w: W, h: H) else {
            print("  SKIP: glslpp render failed"); return false
        }
        guard let px2 = renderShader(device: device, vertLib: vertLib, fragLib: lib2,
                                     texture: texture, uniformBuf: uniformBuf, w: W, h: H) else {
            print("  SKIP: spirv-cross render failed"); return false
        }
        
        let nb1 = countNonBlack(px1, w: W, h: H)
        let nb2 = countNonBlack(px2, w: W, h: H)
        let r = comparePixels(px1, px2, w: W, h: H)
        
        let status = r.maxDiff <= 1 ? "✅ MATCH" : "❌ DIFFER"
        print("  glslpp non-black: \(nb1)/\(W*H), spirv-cross: \(nb2)/\(W*H)")
        print("  Different pixels: \(r.diffPixels)/\(W*H), max diff: \(r.maxDiff), avg: \(String(format:"%.4f", r.avgDiff))")
        print("  \(status)")
        
        return r.maxDiff <= 1
    } catch {
        print("  ERROR: \(error)"); return false
    }
}

switch mode {
case "pair":
    guard args.count >= 4 else { print("Need 2 MSL files"); exit(1) }
    let glslppPath = args[2]
    let spirvcrossPath = args[3]
    let prefix = args.count > 4 ? args[4] : "/tmp/batch_compare"
    let ok = comparePair(device: device, vertLib: vertLib, texture: texture,
                         glslppPath: glslppPath, spirvcrossPath: spirvcrossPath, prefix: prefix)
    exit(ok ? 0 : 1)

case "list":
    guard args.count >= 3 else { print("Need list file"); exit(1) }
    let listPath = args[2]
    let contents = try! String(contentsOfFile: listPath, encoding: .utf8)
    let lines = contents.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
    
    var match = 0, differ = 0, skip = 0
    for line in lines {
        let parts = line.components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 2 else { continue }
        let ok = comparePair(device: device, vertLib: vertLib, texture: texture,
                             glslppPath: parts[0], spirvcrossPath: parts[1], prefix: "/tmp/batch_\(match+differ+skip)")
        if ok { match += 1 } else { differ += 1 }
    }
    
    print("""

    === BATCH SUMMARY ===
    Match: \(match)
    Differ: \(differ)
    Total: \(match + differ)
    """)

default:
    print("Unknown mode: \(mode)"); exit(1)
}

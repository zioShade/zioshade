import Metal
import Foundation

// Vertex-shader differential harness (the vertex analog of ShaderCompare.swift).
//
// A vertex shader's observable output is where it places its vertices (gl_Position, in
// clip space). We render a TRIANGLE through the vertex-shader-under-test with a fixed set
// of known input attributes/uniforms and a solid-white fragment shader: the rasterised
// coverage is a pure function of the computed gl_Positions. Rendering both zioshade's MSL
// and the reference (glslang -> spirv-cross) MSL of the SAME vertex GLSL with the SAME
// inputs, a vertex miscompile shifts the triangle and shows up as a pixel diff. The
// comparison is SOUND regardless of whether the triangle lands on-screen: identical inputs
// mean equivalent shaders match and divergent shaders differ; visibility only affects test
// power (an off-screen result is a trivial all-black match, never a false positive).
//
// Inputs are canned: attribute 0 (conventionally the position) gets the three clip-space
// corners of a centred triangle; every other attribute gets small per-vertex values; every
// uniform buffer is filled with a repeating identity-mat4 pattern (so an MVP-style
// `gl_Position = MVP * pos` lands on-screen). Shaders whose signature we cannot supply are
// skipped by the driver, not mis-rendered.

let W = 256, H = 256

func readMSL(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

// Solid-white fragment: the rasterised coverage of the triangle is what we compare.
let fragMSL = """
#include <metal_stdlib>
using namespace metal;
struct FragIn { float4 position [[position]]; };
fragment float4 solid_frag(FragIn in [[stage_in]]) { return float4(1.0, 1.0, 1.0, 1.0); }
"""

// One [[attribute(n)]] slot parsed from the MSL: its index and component count.
struct Attr { let index: Int; let components: Int }

// Parse `<type> <name> [[attribute(N)]];` lines. Supported types: float, float2/3/4,
// int, uint (int/uint treated as one 32-bit component, packed as float bits is wrong, so
// we return nil for integer attributes -> driver skips, matching the fragment harness's
// conservative "can't feed it correctly -> skip" stance).
func parseAttributes(_ msl: String) -> [Attr]? {
    var attrs: [Attr] = []
    for line in msl.split(separator: "\n") {
        guard line.contains("[[attribute(") else { continue }
        guard let idxRange = line.range(of: "[[attribute("),
              let closeRange = line.range(of: ")]]", range: idxRange.upperBound..<line.endIndex) else { return nil }
        guard let idx = Int(line[idxRange.upperBound..<closeRange.lowerBound].trimmingCharacters(in: .whitespaces)) else { return nil }
        let comps: Int
        if line.contains("float4") { comps = 4 }
        else if line.contains("float3") { comps = 3 }
        else if line.contains("float2") { comps = 2 }
        else if line.contains("float ") { comps = 1 }
        else { return nil }  // integer / matrix / unsupported attribute -> skip this shader
        attrs.append(Attr(index: idx, components: comps))
    }
    return attrs
}

// Parse the highest [[buffer(N)]] index used (uniform buffers we must bind).
func parseBufferIndices(_ msl: String) -> [Int] {
    var idxs = Set<Int>()
    var search = msl.startIndex
    while let r = msl.range(of: "[[buffer(", range: search..<msl.endIndex) {
        if let close = msl.range(of: ")]]", range: r.upperBound..<msl.endIndex),
           let n = Int(msl[r.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)) {
            idxs.insert(n)
        }
        search = r.upperBound
    }
    return idxs.sorted()
}

// Build the interleaved vertex buffer + descriptor for 3 vertices.
func makeVertexBuffer(device: MTLDevice, attrs: [Attr]) -> (MTLBuffer, MTLVertexDescriptor) {
    // A fullscreen-triangle corner pattern for attribute 0 (conventionally position): it
    // over-covers the viewport, so even a shader that scales/offsets the position modestly
    // still rasterises something (more coverage than a small centred triangle). Small
    // per-vertex values elsewhere.
    let corners: [[Float]] = [[-1.0, -1.0, 0.0, 1.0], [3.0, -1.0, 0.0, 1.0], [-1.0, 3.0, 0.0, 1.0]]
    let sorted = attrs.sorted { $0.index < $1.index }
    var stride = 0
    for a in sorted { stride += a.components * 4 }
    if stride == 0 { stride = 4 }

    var bytes = [Float]()
    for v in 0..<3 {
        for a in sorted {
            for c in 0..<a.components {
                if a.index == 0 {
                    bytes.append(c < 4 ? corners[v][c] : 0.0)
                } else {
                    // Distinct, small, per-(vertex,attr,component) values.
                    bytes.append(Float(v + 1) * 0.1 + Float(a.index) * 0.01 + Float(c) * 0.001)
                }
            }
        }
    }
    let buf = device.makeBuffer(bytes: bytes, length: max(bytes.count * 4, stride * 3))!

    let vd = MTLVertexDescriptor()
    var offset = 0
    for a in sorted {
        vd.attributes[a.index].format = [1: .float, 2: .float2, 3: .float3, 4: .float4][a.components]!
        vd.attributes[a.index].offset = offset
        vd.attributes[a.index].bufferIndex = 30  // stage_in buffer slot (kept clear of uniform slots)
        offset += a.components * 4
    }
    vd.layouts[30].stride = stride
    vd.layouts[30].stepFunction = .perVertex
    vd.layouts[30].stepRate = 1
    return (buf, vd)
}

// A uniform buffer filled with a repeating identity-mat4 pattern (column-major), so an
// MVP-style transform reduces to gl_Position = position and lands on-screen.
func makeUniformBuffer(device: MTLDevice) -> MTLBuffer {
    let floatsPerMat = 16
    let mats = 16
    var data = [Float](repeating: 0, count: floatsPerMat * mats)
    for m in 0..<mats {
        for i in 0..<4 { data[m * floatsPerMat + i * 4 + i] = 1.0 }  // identity diagonal
    }
    return device.makeBuffer(bytes: data, length: data.count * 4)!
}

func renderVertex(device: MTLDevice, mslPath: String) -> [UInt8]? {
    guard let msl = try? readMSL(mslPath) else { return nil }
    guard let attrs = parseAttributes(msl) else { return nil }
    guard let lib = try? device.makeLibrary(source: msl, options: nil) else { return nil }
    guard let vfn = lib.makeFunction(name: "main0") else { return nil }
    guard let fragLib = try? device.makeLibrary(source: fragMSL, options: nil),
          let ffn = fragLib.makeFunction(name: "solid_frag") else { return nil }

    let (vbuf, vdesc) = makeVertexBuffer(device: device, attrs: attrs)
    let ubuf = makeUniformBuffer(device: device)

    let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
    outDesc.usage = [.renderTarget, .shaderRead]
    let outTex = device.makeTexture(descriptor: outDesc)!

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = outTex
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    pass.colorAttachments[0].storeAction = .store

    let pipe = MTLRenderPipelineDescriptor()
    pipe.vertexFunction = vfn
    pipe.fragmentFunction = ffn
    pipe.vertexDescriptor = vdesc
    pipe.colorAttachments[0].pixelFormat = .rgba8Unorm
    guard let pso = try? device.makeRenderPipelineState(descriptor: pipe) else { return nil }

    let queue = device.makeCommandQueue()!
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
    enc.setRenderPipelineState(pso)
    enc.setVertexBuffer(vbuf, offset: 0, index: 30)
    // Bind the identity-uniform buffer to every uniform slot the shader declares.
    for bi in parseBufferIndices(msl) where bi != 30 {
        enc.setVertexBuffer(ubuf, offset: 0, index: bi)
    }
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()

    var px = [UInt8](repeating: 0, count: W * H * 4)
    outTex.getBytes(&px, bytesPerRow: W * 4, from: MTLRegion(origin: .init(x: 0, y: 0, z: 0), size: .init(width: W, height: H, depth: 1)), mipmapLevel: 0)
    return px
}

func comparePixels(_ a: [UInt8], _ b: [UInt8]) -> (maxDiff: Int, diffPixels: Int) {
    var maxD = 0, diffPx = 0
    var i = 0
    while i < a.count {
        var pd = false
        for j in i..<min(i + 4, a.count) {
            let d = abs(Int(a[j]) - Int(b[j])); maxD = max(maxD, d); if d > 0 { pd = true }
        }
        if pd { diffPx += 1 }
        i += 4
    }
    return (maxD, diffPx)
}

// ---- main ----
let args = CommandLine.arguments
guard args.count >= 3 else { print("Usage: VertexCompare <zioshade.msl> <reference.msl>"); exit(1) }
guard let device = MTLCreateSystemDefaultDevice() else { print("ERROR: No Metal device"); exit(2) }

guard let px1 = renderVertex(device: device, mslPath: args[1]) else { print("SKIP: cannot render \(args[1])"); exit(3) }
guard let px2 = renderVertex(device: device, mslPath: args[2]) else { print("SKIP: cannot render \(args[2])"); exit(3) }

let r = comparePixels(px1, px2)
// An all-black pair (no triangle drawn by either) carries no signal -> report it distinctly.
let coverage1 = px1.enumerated().contains { $0.offset % 4 == 0 && $0.element > 8 }
print("Different: \(r.diffPixels)  Max channel diff: \(r.maxDiff)  Coverage: \(coverage1 ? "yes" : "none")")
print(r.maxDiff <= 1 ? "MATCH" : "DIFFER (max diff: \(r.maxDiff))")

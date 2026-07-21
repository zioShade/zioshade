import Metal
import Foundation

// Numeric vertex differential: capture each vertex's computed gl_Position into a buffer
// and diff the buffers, instead of rasterising a triangle. This gives coverage for EVERY
// vertex shader regardless of where its gl_Position lands (the rasterisation harness in
// VertexCompare.swift only has test power when the triangle is on-screen). We inject a
// `device float4*` output into the spirv-cross-emitted MSL vertex entry and write
// out.gl_Position to it, then run a rasterisation-disabled vertex-only pass over N vertices
// with fixed known attributes + identity uniforms, and compare the captured positions of
// zioshade's MSL against the reference (glslang -> spirv-cross) MSL.
//
// spirv-cross vertex MSL is highly regular:
//   vertex main0_out main0(<params>) { main0_out out = {}; ... ; return out; }
//   struct main0_out { ...; float4 gl_Position [[position]]; };
// so the transform is a reliable text edit.

let N = 6  // test vertices

struct Attr { let index: Int; let components: Int }

func readMSL(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }

func parseAttributes(_ msl: String) -> [Attr]? {
    var attrs: [Attr] = []
    for line in msl.split(separator: "\n") where line.contains("[[attribute(") {
        guard let a = line.range(of: "[[attribute("),
              let b = line.range(of: ")]]", range: a.upperBound..<line.endIndex),
              let idx = Int(line[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespaces)) else { return nil }
        let comps: Int
        if line.contains("float4") { comps = 4 } else if line.contains("float3") { comps = 3 }
        else if line.contains("float2") { comps = 2 } else if line.contains("float ") { comps = 1 }
        else { return nil }  // integer/matrix attribute -> skip this shader
        attrs.append(Attr(index: idx, components: comps))
    }
    return attrs
}

func parseBufferIndices(_ msl: String) -> [Int] {
    var s = Set<Int>(); var i = msl.startIndex
    while let r = msl.range(of: "[[buffer(", range: i..<msl.endIndex) {
        if let c = msl.range(of: ")]]", range: r.upperBound..<msl.endIndex),
           let n = Int(msl[r.upperBound..<c.lowerBound].trimmingCharacters(in: .whitespaces)) { s.insert(n) }
        i = r.upperBound
    }
    return s.sorted()
}

// Inject the capture output. Returns the transformed MSL, or nil if the expected shape
// (a single-line `vertex ... main0(...)` signature + a `return out;`) is not found.
func injectCapture(_ msl: String, capIndex: Int) -> String? {
    guard msl.contains("[[position]]") else { return nil }
    let lines = msl.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Reuse an existing [[vertex_id]] param name if present; else add one.
    var vidExpr = "zzvid"
    var addVid = true
    for l in lines where l.contains("[[vertex_id]]") {
        // e.g. "uint gl_VertexIndex [[vertex_id]]" -> capture the identifier before [[vertex_id]]
        if let r = l.range(of: "[[vertex_id]]") {
            let pre = l[l.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            if let name = pre.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "(" }).last {
                vidExpr = String(name); addVid = false
            }
        }
    }
    var out: [String] = []
    var didSig = false, didRet = false
    for var l in lines {
        if !didSig, l.hasPrefix("vertex "), let paren = l.range(of: "main0(") {
            // Find the MATCHING close paren of the param list by depth counting -- the
            // params contain nested parens ([[buffer(0)]], [[texture(0)]], ...), so a naive
            // "first )" lands inside an attribute and corrupts the signature.
            var depth = 1
            var idx = paren.upperBound
            var matchIdx: String.Index? = nil
            while idx < l.endIndex {
                let ch = l[idx]
                if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1; if depth == 0 { matchIdx = idx; break } }
                idx = l.index(after: idx)
            }
            if let close = matchIdx {
                let hasParams = l[paren.upperBound..<close].trimmingCharacters(in: .whitespaces).count > 0
                var inject = "\(hasParams ? ", " : "")device float4* zzcap [[buffer(\(capIndex))]]"
                if addVid { inject += ", uint zzvid [[vertex_id]]" }
                l.replaceSubrange(close..<close, with: inject)
                didSig = true
            }
        }
        if !didRet, didSig, l.contains("return out;") {
            l = l.replacingOccurrences(of: "return out;", with: "zzcap[\(vidExpr)] = out.gl_Position; return out;")
            didRet = true
        }
        out.append(l)
    }
    return (didSig && didRet) ? out.joined(separator: "\n") : nil
}

func makeVertexBuffer(_ device: MTLDevice, _ attrs: [Attr]) -> (MTLBuffer, MTLVertexDescriptor) {
    let sorted = attrs.sorted { $0.index < $1.index }
    var stride = 0; for a in sorted { stride += a.components * 4 }
    if stride == 0 { stride = 4 }
    var bytes = [Float]()
    for v in 0..<N { for a in sorted { for c in 0..<a.components {
        // Deterministic, varied per (vertex, attribute, component), spread around 0.
        bytes.append(Float(v + 1) * 0.37 + Float(a.index) * 0.13 + Float(c) * 0.05 - 0.9)
    }}}
    let buf = device.makeBuffer(bytes: bytes, length: max(bytes.count * 4, stride * N))!
    let vd = MTLVertexDescriptor()
    var off = 0
    for a in sorted {
        vd.attributes[a.index].format = [1: .float, 2: .float2, 3: .float3, 4: .float4][a.components]!
        vd.attributes[a.index].offset = off
        vd.attributes[a.index].bufferIndex = 28
        off += a.components * 4
    }
    vd.layouts[28].stride = stride; vd.layouts[28].stepFunction = .perVertex; vd.layouts[28].stepRate = 1
    return (buf, vd)
}

func makeUniformBuffer(_ device: MTLDevice) -> MTLBuffer {
    var data = [Float](repeating: 0, count: 16 * 16)
    for m in 0..<16 { for i in 0..<4 { data[m*16 + i*4 + i] = 1.0 } }  // repeated identity mat4
    return device.makeBuffer(bytes: data, length: data.count * 4)!
}

// Run the (transformed) MSL and return the N captured gl_Positions, or nil on any failure.
func capture(_ device: MTLDevice, mslPath: String, capIndex: Int) -> [SIMD4<Float>]? {
    let dbg = ProcessInfo.processInfo.environment["VN_DEBUG"] == "1"
    guard let msl = readMSL(mslPath), let attrs = parseAttributes(msl) else { if dbg { FileHandle.standardError.write("read/parseAttr failed\n".data(using: .utf8)!) }; return nil }
    guard let injected = injectCapture(msl, capIndex: capIndex) else { if dbg { FileHandle.standardError.write("injectCapture failed\n".data(using: .utf8)!) }; return nil }
    if dbg { FileHandle.standardError.write("--- injected ---\n\(injected)\n".data(using: .utf8)!) }
    let lib: MTLLibrary
    do { lib = try device.makeLibrary(source: injected, options: nil) }
    catch { if dbg { FileHandle.standardError.write("makeLibrary: \(error)\n".data(using: .utf8)!) }; return nil }
    guard let vfn = lib.makeFunction(name: "main0") else { if dbg { FileHandle.standardError.write("no main0\n".data(using: .utf8)!) }; return nil }
    let (vbuf, vdesc) = makeVertexBuffer(device, attrs)
    let ubuf = makeUniformBuffer(device)
    let capBuf = device.makeBuffer(length: N * 16, options: .storageModeShared)!

    // Rasterisation stays ON (a void return type would be required to disable it): the
    // vertex shader runs for every vertex and writes the capture buffer regardless of
    // whether the point is clipped, so we get numeric coverage for all N vertices. Draw
    // points into a throwaway 1x1 target with a trivial fragment.
    let fragLib = try! device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\nfragment half4 zzfrag() { return half4(0); }", options: nil)
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = vfn
    pd.fragmentFunction = fragLib.makeFunction(name: "zzfrag")
    pd.vertexDescriptor = vdesc
    pd.colorAttachments[0].pixelFormat = .r8Unorm
    let pso: MTLRenderPipelineState
    do { pso = try device.makeRenderPipelineState(descriptor: pd) }
    catch { if dbg { FileHandle.standardError.write("makePipeline: \(error)\n".data(using: .utf8)!) }; return nil }

    let tdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
    tdesc.usage = [.renderTarget]
    let tgt = device.makeTexture(descriptor: tdesc)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = tgt
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let q = device.makeCommandQueue()!
    let cb = q.makeCommandBuffer()!
    guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    enc.setRenderPipelineState(pso)
    enc.setVertexBuffer(vbuf, offset: 0, index: 28)
    enc.setVertexBuffer(capBuf, offset: 0, index: capIndex)
    for bi in parseBufferIndices(msl) where bi != 28 && bi != capIndex { enc.setVertexBuffer(ubuf, offset: 0, index: bi) }
    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: N)
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    if cb.error != nil { return nil }

    let ptr = capBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: N)
    return (0..<N).map { ptr[$0] }
}

// ---- main ----
let args = CommandLine.arguments
guard args.count >= 3 else { print("Usage: VertexNumeric <zioshade.msl> <reference.msl>"); exit(1) }
guard let device = MTLCreateSystemDefaultDevice() else { print("ERROR: no Metal device"); exit(2) }

guard let a = capture(device, mslPath: args[1], capIndex: 29) else { print("SKIP: cannot capture \(args[1])"); exit(3) }
guard let b = capture(device, mslPath: args[2], capIndex: 29) else { print("SKIP: cannot capture \(args[2])"); exit(3) }

var maxAbs: Float = 0, maxRel: Float = 0
var anyNonZero = false
for i in 0..<N {
    for c in 0..<4 {
        let x = a[i][c], y = b[i][c]
        if abs(x) > 1e-6 || abs(y) > 1e-6 { anyNonZero = true }
        let d = abs(x - y); maxAbs = max(maxAbs, d)
        let denom = max(abs(x), abs(y), 1e-6)
        maxRel = max(maxRel, d / denom)
    }
}
// Same-backend frontend oracle: expect bit-near-exact. Tolerate tiny fp (1e-4 rel), flag more.
let match = maxAbs <= 1e-5 || maxRel <= 1e-4
print(String(format: "maxAbs=%.6g maxRel=%.6g nonzero=%@", maxAbs, maxRel, anyNonZero ? "yes" : "no"))
print(match ? "MATCH" : "DIFFER")

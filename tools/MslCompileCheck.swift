// MSL compile-check: read a Metal Shading Language source file and try to compile
// it with MTLDevice.makeLibrary. Exit 0 if Metal accepts it, 1 (with the compiler
// diagnostic on stderr) if it rejects it. This is the MSL analog of glslangValidator
// for GLSL and naga for WGSL — a real backend-validity oracle, used by
// tools/msl_validity_sweep.sh to gate on silently-invalid MSL output.
//
// Usage: MslCompileCheck <file.metal>
import Metal
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: MslCompileCheck <file.metal>\n".data(using: .utf8)!)
    exit(2)
}
let path = CommandLine.arguments[1]
guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
    exit(2)
}
guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write("no Metal device\n".data(using: .utf8)!)
    exit(2)
}
do {
    _ = try device.makeLibrary(source: src, options: nil)
    exit(0)
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}

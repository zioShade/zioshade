#version 450
// Regression guard: WGSL mandates u32 for the vertex_index/instance_index
// built-ins, but glslang types gl_VertexIndex/gl_InstanceIndex as signed i32.
// The WGSL backend must emit a u32 @builtin parameter and an i32 conversion
// (NOT `@builtin(vertex_index) ...: i32`, which naga rejects).
layout(location = 0) out vec4 col;
void main() {
    gl_Position = vec4(float(gl_VertexIndex), float(gl_InstanceIndex), 0.0, 1.0);
    col = vec4(1.0);
}

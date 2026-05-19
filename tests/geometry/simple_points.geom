#version 450
layout(points) in;
layout(points, max_vertices = 1) out;

void main() {
    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
    EmitVertex();
    EndPrimitive();
}

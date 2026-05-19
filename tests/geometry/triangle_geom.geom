#version 450
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

void main() {
    for (int i = 0; i < 3; i++) {
        gl_Position = vec4(float(i) * 0.5 - 0.5, 0.0, 0.0, 1.0);
        EmitVertex();
    }
    EndPrimitive();
}

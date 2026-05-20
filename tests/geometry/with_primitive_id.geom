#version 450
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

void main() {
    int pid = gl_PrimitiveIDIn;
    float offset = float(pid) * 0.1;
    for (int i = 0; i < 3; i++) {
        float x = float(i) * 0.5 - 0.5 + offset;
        gl_Position = vec4(x, 0.0, 0.0, 1.0);
        EmitVertex();
    }
    EndPrimitive();
}

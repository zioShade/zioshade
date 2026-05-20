#version 450
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

float computeOffset(int idx) {
    return float(idx) * 0.2 - 0.2;
}

void main() {
    for (int i = 0; i < 3; i++) {
        float off = computeOffset(i);
        gl_Position = vec4(off, float(i) * 0.3 - 0.3, 0.0, 1.0);
        EmitVertex();
    }
    EndPrimitive();
}

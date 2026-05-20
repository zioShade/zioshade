#version 450
layout(triangles) in;
layout(triangle_strip, max_vertices = 6) out;

void main() {
    for (int i = 0; i < 3; i++) {
        float angle = float(i) * 2.094395; // 2*pi/3
        gl_Position = vec4(cos(angle) * 0.5, sin(angle) * 0.5, 0.0, 1.0);
        EmitVertex();
    }
    EndPrimitive();
    for (int i = 0; i < 3; i++) {
        float angle = float(i) * 2.094395 + 0.5;
        gl_Position = vec4(cos(angle) * 0.3, sin(angle) * 0.3, 0.0, 1.0);
        EmitVertex();
    }
    EndPrimitive();
}

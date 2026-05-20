#version 450
layout(lines_adjacency) in;
layout(line_strip, max_vertices = 4) out;

void main() {
    for (int i = 0; i < 4; i++) {
        float x = float(i) * 0.3 - 0.5;
        gl_Position = vec4(x, 0.0, 0.0, 1.0);
        EmitVertex();
    }
    EndPrimitive();
}

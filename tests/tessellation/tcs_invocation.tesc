#version 450
layout(vertices = 3) out;

void main() {
    int id = gl_InvocationID;
    float x = float(id) * 0.3;
    gl_Position = vec4(x, 0.0, 0.0, 1.0);
}

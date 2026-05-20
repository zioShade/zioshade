#version 450
layout(vertices = 3) out;

void main() {
    int n = gl_in.length();
    gl_TessLevelOuter[0] = float(n);
    gl_TessLevelOuter[1] = float(n);
    gl_TessLevelInner[0] = float(n);
    gl_Position = vec4(float(n), 0.0, 0.0, 1.0);
}

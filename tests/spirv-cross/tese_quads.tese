#version 310 es
layout(quads, equal_spacing) in;

void main() {
    float u = gl_TessCoord.x;
    float v = gl_TessCoord.y;
    gl_Position = vec4(u * 2.0 - 1.0, v * 2.0 - 1.0, 0.0, 1.0);
}

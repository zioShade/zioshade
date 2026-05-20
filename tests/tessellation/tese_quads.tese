#version 450
layout(quads, fractional_even_spacing, ccw) in;

void main() {
    gl_Position = vec4(gl_TessCoord, 1.0);
}

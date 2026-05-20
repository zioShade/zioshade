#version 450
layout(isolines, fractional_odd_spacing, cw) in;

void main() {
    gl_Position = vec4(gl_TessCoord.x, 0.0, 0.0, 1.0);
}

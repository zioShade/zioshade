#version 450
layout(triangles, equal_spacing, ccw) in;

void main() {
    gl_Position = vec4(gl_TessCoord, 1.0);
}

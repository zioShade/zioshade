#version 450
layout(triangles, equal_spacing, ccw) in;

void main() {
    float outer0 = gl_TessLevelOuter[0];
    float inner0 = gl_TessLevelInner[0];
    float scale = outer0 + inner0;
    gl_Position = vec4(gl_TessCoord.x * scale, gl_TessCoord.y, gl_TessCoord.z, 1.0);
}

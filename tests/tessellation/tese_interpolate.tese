#version 450
layout(triangles, equal_spacing, ccw) in;

void main() {
    // Read from all three input vertices
    vec4 p0 = gl_in[0].gl_Position;
    vec4 p1 = gl_in[1].gl_Position;
    vec4 p2 = gl_in[2].gl_Position;

    // Interpolate using tessellation coordinates
    gl_Position = p0 * gl_TessCoord.x + p1 * gl_TessCoord.y + p2 * gl_TessCoord.z;
}

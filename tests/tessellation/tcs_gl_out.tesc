#version 450
layout(vertices = 3) out;

void main() {
    int id = gl_InvocationID;

    // Write position through gl_out array
    gl_out[id].gl_Position = vec4(float(id) * 0.3, 0.0, 0.0, 1.0);

    gl_TessLevelOuter[0] = 1.0;
    gl_TessLevelOuter[1] = 1.0;
    gl_TessLevelOuter[2] = 1.0;
    gl_TessLevelOuter[3] = 1.0;
    gl_TessLevelInner[0] = 1.0;
}

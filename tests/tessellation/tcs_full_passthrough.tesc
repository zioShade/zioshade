#version 450
layout(vertices = 3) out;

void main() {
    int id = gl_InvocationID;

    // Passthrough: gl_out[id] = gl_in[id]
    gl_out[id].gl_Position = gl_in[id].gl_Position;

    gl_TessLevelOuter[0] = 4.0;
    gl_TessLevelOuter[1] = 4.0;
    gl_TessLevelOuter[2] = 4.0;
    gl_TessLevelOuter[3] = 4.0;
    gl_TessLevelInner[0] = 4.0;
    gl_TessLevelInner[1] = 4.0;
}

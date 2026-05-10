#version 450
layout(vertices = 3) out;
layout(location = 0) in vec3 in_normal[];
layout(location = 0) out vec3 out_normal[];
void main() {
    out_normal[gl_InvocationID] = in_normal[gl_InvocationID];
    gl_TessLevelOuter[0] = 1.0;
    gl_TessLevelOuter[1] = 1.0;
    gl_TessLevelOuter[2] = 1.0;
    gl_TessLevelInner[0] = 1.0;
    gl_out[gl_InvocationID].gl_Position = gl_in[gl_InvocationID].gl_Position;
}

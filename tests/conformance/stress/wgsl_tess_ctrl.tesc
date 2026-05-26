// Test: tessellation control shader
#version 450

layout(vertices = 4) out;

layout(location = 0) in vec3 vPosition[];
layout(location = 0) out vec3 tcPosition[];

void main() {
    tcPosition[gl_InvocationID] = vPosition[gl_InvocationID];
    
    if (gl_InvocationID == 0) {
        gl_TessLevelInner[0] = 4.0;
        gl_TessLevelInner[1] = 4.0;
        gl_TessLevelOuter[0] = 4.0;
        gl_TessLevelOuter[1] = 4.0;
        gl_TessLevelOuter[2] = 4.0;
        gl_TessLevelOuter[3] = 4.0;
    }
}

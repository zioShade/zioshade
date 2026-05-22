#version 450
layout(vertices = 4) out;

void main() {
    // Pass through position
    gl_out[gl_InvocationID].gl_Position = gl_in[gl_InvocationID].gl_Position;
    
    // Only invocation 0 sets tess levels
    if (gl_InvocationID == 0) {
        float inner = 4.0;
        gl_TessLevelInner[0] = inner;
        gl_TessLevelInner[1] = inner;
        
        gl_TessLevelOuter[0] = 2.0;
        gl_TessLevelOuter[1] = 4.0;
        gl_TessLevelOuter[2] = 2.0;
        gl_TessLevelOuter[3] = 4.0;
    }
}

#version 450
layout(triangles) in;
layout(triangle_strip, max_vertices = 9) out;

uniform mat4 u_mvp;

void main() {
    for (int i = 0; i < 3; i++) {
        vec4 pos = gl_in[i].gl_Position;
        
        // Emit original
        gl_Position = u_mvp * pos;
        EmitVertex();
        
        // Emit scaled copy
        gl_Position = u_mvp * pos * 0.5;
        EmitVertex();
        
        // Emit inverted copy
        gl_Position = u_mvp * (-pos);
        EmitVertex();
    }
    EndPrimitive();
}

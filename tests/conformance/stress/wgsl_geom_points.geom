// Tests: geometry shader pass-through
#version 450
layout(points) in;
layout(triangle_strip, max_vertices = 3) out;
uniform float u_size;

void main() {
    vec4 pos = gl_in[0].gl_Position;
    float s = u_size * 0.01;
    
    gl_Position = pos + vec4(-s, -s, 0.0, 0.0);
    EmitVertex();
    gl_Position = pos + vec4(s, -s, 0.0, 0.0);
    EmitVertex();
    gl_Position = pos + vec4(0.0, s, 0.0, 0.0);
    EmitVertex();
    EndPrimitive();
}

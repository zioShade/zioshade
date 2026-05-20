#version 310 es
layout(points) in;
layout(triangle_strip, max_vertices = 4) out;

void main() {
    vec4 center = gl_in[0].gl_Position;
    float size = 0.05;
    
    gl_Position = center + vec4(-size, -size, 0.0, 0.0);
    EmitVertex();
    gl_Position = center + vec4(size, -size, 0.0, 0.0);
    EmitVertex();
    gl_Position = center + vec4(-size, size, 0.0, 0.0);
    EmitVertex();
    gl_Position = center + vec4(size, size, 0.0, 0.0);
    EmitVertex();
    EndPrimitive();
}

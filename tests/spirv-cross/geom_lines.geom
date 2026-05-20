#version 310 es
layout(lines) in;
layout(line_strip, max_vertices = 4) out;

void main() {
    vec4 a = gl_in[0].gl_Position;
    vec4 b = gl_in[1].gl_Position;
    vec4 mid = (a + b) * 0.5;
    vec4 offset = vec4(0.0, 0.02, 0.0, 0.0);
    
    gl_Position = a;
    EmitVertex();
    gl_Position = mid + offset;
    EmitVertex();
    gl_Position = mid - offset;
    EmitVertex();
    gl_Position = b;
    EmitVertex();
    EndPrimitive();
}

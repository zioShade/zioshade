#version 450
layout(lines) in;
layout(triangle_strip, max_vertices = 6) out;

void main() {
    // Extrude a line into a quad (two triangles)
    vec4 a = gl_in[0].gl_Position;
    vec4 b = gl_in[1].gl_Position;

    vec4 offset = vec4(0.0, 0.1, 0.0, 0.0);

    // Triangle 1
    gl_Position = a;
    EmitVertex();
    gl_Position = a + offset;
    EmitVertex();
    gl_Position = b;
    EmitVertex();
    EndPrimitive();

    // Triangle 2
    gl_Position = b;
    EmitVertex();
    gl_Position = a + offset;
    EmitVertex();
    gl_Position = b + offset;
    EmitVertex();
    EndPrimitive();
}

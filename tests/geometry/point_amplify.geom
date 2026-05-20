#version 450
layout(points) in;
layout(points, max_vertices = 2) out;

void main() {
    gl_Position = vec4(-0.5, 0.0, 0.0, 1.0);
    EmitVertex();
    EndPrimitive();
    gl_Position = vec4(0.5, 0.0, 0.0, 1.0);
    EmitVertex();
    EndPrimitive();
}

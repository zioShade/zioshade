#version 450
layout(points) in;
layout(line_strip, max_vertices = 4) out;

void main() {
    // Draw a diamond shape
    gl_Position = vec4( 0.0,  0.5, 0.0, 1.0);
    EmitVertex();
    gl_Position = vec4( 0.5,  0.0, 0.0, 1.0);
    EmitVertex();
    gl_Position = vec4( 0.0, -0.5, 0.0, 1.0);
    EmitVertex();
    gl_Position = vec4(-0.5,  0.0, 0.0, 1.0);
    EmitVertex();
    EndPrimitive();
}

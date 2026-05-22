#version 450
layout(points) in;
layout(line_strip, max_vertices = 4) out;

uniform float u_time;

void main() {
    vec4 center = gl_in[0].gl_Position;
    float size = 0.1 + 0.05 * sin(u_time);
    
    // Draw a diamond shape around each point
    gl_Position = center + vec4(0.0, size, 0.0, 0.0);
    EmitVertex();
    
    gl_Position = center + vec4(size, 0.0, 0.0, 0.0);
    EmitVertex();
    
    gl_Position = center + vec4(0.0, -size, 0.0, 0.0);
    EmitVertex();
    
    gl_Position = center + vec4(-size, 0.0, 0.0, 0.0);
    EmitVertex();
    
    EndPrimitive();
}

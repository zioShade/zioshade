#version 450
layout(quads, equal_spacing, ccw) in;

void main() {
    float u = gl_TessCoord.x;
    float v = gl_TessCoord.y;
    
    // Bilinear interpolation of 4 control points
    vec3 p0 = gl_in[0].gl_Position.xyz;
    vec3 p1 = gl_in[1].gl_Position.xyz;
    vec3 p2 = gl_in[2].gl_Position.xyz;
    vec3 p3 = gl_in[3].gl_Position.xyz;
    
    vec3 bottom = mix(p0, p1, u);
    vec3 top = mix(p3, p2, u);
    vec3 pos = mix(bottom, top, v);
    
    gl_Position = vec4(pos, 1.0);
}

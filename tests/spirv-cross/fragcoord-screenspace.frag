#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test using gl_FragCoord for screen-space effects
void main() {
    vec2 screen = gl_FragCoord.xy / vec2(800.0, 600.0);
    float d = gl_FragCoord.z;
    
    // Use all components
    vec4 fc = gl_FragCoord;
    float inv_w = 1.0 / fc.w;
    
    vec3 col = vec3(screen, d * inv_w);
    fragColor = vec4(col, 1.0);
}

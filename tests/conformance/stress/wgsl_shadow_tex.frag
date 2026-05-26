// Test: depth texture sampling and comparison
#version 450

layout(binding = 0) uniform sampler2DShadow uShadow;
layout(binding = 1) uniform sampler2D uDepth;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    // Regular texture sampling
    vec4 depth = texture(uDepth, uv);
    
    // Shadow comparison
    float shadow = texture(uShadow, vec3(uv, depth.r));
    
    fragColor = vec4(shadow, depth.r, 0.0, 1.0);
}

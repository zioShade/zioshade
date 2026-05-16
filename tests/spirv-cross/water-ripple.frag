#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Ripple effect on water
void main() {
    vec2 p = uv * 2.0 - 1.0;
    
    float dist = length(p);
    float time = 1.0;  // Fixed time for conformance
    
    // Multiple ripples from center
    float ripple = 0.0;
    for (int i = 0; i < 3; i++) {
        float offset = float(i) * 1.5;
        float wave = sin((dist - offset) * 15.0);
        float envelope = exp(-dist * 2.0);
        ripple += wave * envelope;
    }
    
    // Color the ripple
    vec3 col = vec3(0.1, 0.2, 0.4);
    col += vec3(0.3, 0.5, 0.7) * (ripple * 0.5 + 0.5);
    col *= 1.0 - dist * 0.3;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

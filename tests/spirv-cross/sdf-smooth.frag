#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test smooth min/max for SDF blending
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

void main() {
    vec2 p = uv * 4.0 - 2.0;
    
    float d1 = length(p - vec2(-0.5, 0.0)) - 0.7;
    float d2 = length(p - vec2(0.5, 0.0)) - 0.7;
    float d3 = length(p - vec2(0.0, 0.8)) - 0.5;
    
    float blended = smin(smin(d1, d2, 0.3), d3, 0.3);
    
    float fill = 1.0 - smoothstep(0.0, 0.02, blended);
    
    vec3 col = vec3(0.05);
    col += vec3(0.3, 0.6, 0.9) * fill;
    col += vec3(0.5, 0.3, 0.7) * (1.0 - smoothstep(0.0, 0.05, abs(blended))) * 0.3;
    
    fragColor = vec4(col, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test ferrofluid magnetic spike pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    
    // Spike pattern from overlapping distance fields
    float spikes = 0.0;
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        float angle = fi * 0.5236;
        float spike_r = 0.15 + 0.1 * hash(vec2(fi, fi * 2.0));
        vec2 spike_pos = vec2(cos(angle), sin(angle)) * spike_r;
        float d = length(p - spike_pos);
        float spike = smoothstep(0.03, 0.01, d);
        spikes += spike;
    }
    
    // Central smooth dome
    float dome = smoothstep(0.15, 0.12, r);
    
    // Concentric magnetic field rings
    float field = sin(r * 40.0) * 0.5 + 0.5;
    field *= smoothstep(0.5, 0.2, r);
    
    vec3 col = vec3(0.02);
    col += dome * vec3(0.08, 0.08, 0.1);
    col += spikes * vec3(0.1, 0.1, 0.12);
    col += field * vec3(0.15, 0.2, 0.35) * smoothstep(0.45, 0.15, r);
    
    // Specular highlights
    vec2 hl = p - vec2(-0.05, -0.05);
    float spec = exp(-dot(hl, hl) * 50.0);
    col += spec * 0.3 * dome;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

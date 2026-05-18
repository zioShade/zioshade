#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test radial blur effect
void main() {
    vec2 center = vec2(0.5);
    vec2 d = uv - center;
    float dist = length(d);
    vec2 dir = d / (dist + 0.001);
    
    float accum = 0.0;
    float total = 0.0;
    
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        float offset = fi * 0.01;
        vec2 sample_uv = uv - dir * offset;
        
        // Sample a pattern at the offset position
        float val = sin(sample_uv.x * 20.0) * cos(sample_uv.y * 20.0);
        val = val * 0.5 + 0.5;
        
        float weight = 1.0 - fi / 12.0;
        accum += val * weight;
        total += weight;
    }
    
    float blurred = accum / total;
    
    vec3 col = vec3(blurred, blurred * 0.6, blurred * 0.3);
    col *= 1.0 - dist * 1.2;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

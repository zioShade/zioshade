#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test electric arc / lightning pattern
void main() {
    vec2 p = uv * vec2(4.0, 6.0);
    
    float min_d = 1.0;
    vec2 pos = vec2(0.0, 0.0);
    
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        vec2 next = vec2(
            fi * 0.4 + 0.2,
            sin(fi * 1.5 + uv.x * 2.0) * 0.5 + 3.0
        );
        
        vec2 seg = next - pos;
        float len = length(seg);
        float t = clamp(dot(p - pos, seg) / (len * len + 0.001), 0.0, 1.0);
        float d = length(p - pos - seg * t);
        min_d = min(min_d, d);
        pos = next;
    }
    
    float arc = smoothstep(0.1, 0.03, min_d);
    float glow = exp(-min_d * min_d * 20.0) * 0.5;
    
    vec3 col = vec3(0.02, 0.02, 0.05);
    col += (arc + glow) * vec3(0.5, 0.7, 1.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

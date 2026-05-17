#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test turtle-graphics-like pattern using polar accumulation
void main() {
    vec2 p = uv * 4.0 - 2.0;
    vec2 pos = vec2(0.0);
    float heading = 0.0;
    float total_len = 0.0;
    
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        float step_len = 0.15 + fi * 0.02;
        heading += sin(fi * 1.2) * 0.5;
        
        vec2 new_pos = pos + vec2(cos(heading), sin(heading)) * step_len;
        
        float d = dot(p - (pos + new_pos) * 0.5, p - (pos + new_pos) * 0.5);
        float seg_len = length(new_pos - pos);
        float proj = clamp(dot(p - pos, new_pos - pos) / (seg_len * seg_len + 0.001), 0.0, 1.0);
        float dist = length(p - pos - (new_pos - pos) * proj);
        
        if (dist < 0.05) total_len += 1.0;
        
        pos = new_pos;
    }
    
    float hit = smoothstep(1.5, 0.5, total_len);
    vec3 col = mix(vec3(0.05), vec3(0.4, 0.8, 0.3), hit);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

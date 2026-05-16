#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Radial wipe / clock hand
void main() {
    vec2 p = uv * 2.0 - 1.0;
    float angle = atan(p.y, p.x);
    float dist = length(p);
    
    // Clock face
    float face = smoothstep(0.95, 0.9, dist);
    
    // Hour markers
    float hour_angle = mod(angle + 3.14159, 6.28318);
    float hour_mark = 0.0;
    for (int i = 0; i < 12; i++) {
        float ha = float(i) * 0.5236;
        float da = abs(hour_angle - ha);
        da = min(da, 6.28318 - da);
        hour_mark += smoothstep(0.08, 0.0, da) * smoothstep(0.8, 0.85, dist);
    }
    hour_mark = min(hour_mark, 1.0);
    
    // Clock hand (pointing at 3 o'clock)
    float hand_angle = 0.0;
    float hand_da = abs(hour_angle - hand_angle);
    hand_da = min(hand_da, 6.28318 - hand_da);
    float hand = smoothstep(0.05, 0.0, hand_da) * step(dist, 0.7);
    
    vec3 col = vec3(0.0);
    col += vec3(0.9) * face;
    col += vec3(0.1) * hour_mark;
    col += vec3(0.8, 0.1, 0.1) * hand;
    
    fragColor = vec4(col, 1.0);
}

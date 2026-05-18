#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test art deco geometric pattern
void main() {
    vec2 p = uv * 8.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Chevron / fan shape per tile
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    // Fan arc
    vec2 center = vec2(0.5, 0.0);
    float d = length(fp - center);
    float arc = smoothstep(0.55, 0.52, d) * (1.0 - smoothstep(0.42, 0.45, d));
    
    // Vertical lines
    float lines = 0.0;
    for (int i = 0; i < 4; i++) {
        float x_pos = 0.2 + float(i) * 0.2;
        lines += smoothstep(0.02, 0.01, abs(fp.x - x_pos));
    }
    lines = 1.0 - lines;
    
    // Gold and black palette
    vec3 gold = vec3(0.85, 0.7, 0.3);
    vec3 dark = vec3(0.08, 0.06, 0.04);
    vec3 cream = vec3(0.95, 0.9, 0.8);
    
    vec3 col = dark;
    float is_even = step(0.5, mod(id.x + id.y, 2.0));
    col = mix(col, cream, arc * (0.3 + h * 0.7));
    col = mix(col, gold, lines * 0.5);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

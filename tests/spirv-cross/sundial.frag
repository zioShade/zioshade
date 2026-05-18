#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test sundial with hour markers and gnomon shadow
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Dial face
    float dial = smoothstep(0.42, 0.4, r);
    float rim = smoothstep(0.42, 0.41, r) * (1.0 - smoothstep(0.39, 0.38, r));
    
    // Hour markers (12 lines)
    float markers = 0.0;
    for (int i = 0; i < 12; i++) {
        float angle = float(i) * 0.5236 - 1.5708;
        float diff = abs(a - angle);
        diff = min(diff, 6.2832 - diff);
        float in_range = step(0.25, r) * smoothstep(0.4, 0.38, r);
        markers += smoothstep(0.05, 0.02, diff) * in_range;
    }
    
    // Minute ticks
    float ticks = 0.0;
    for (int i = 0; i < 60; i++) {
        float angle = float(i) * 0.10472 - 1.5708;
        float diff = abs(a - angle);
        diff = min(diff, 6.2832 - diff);
        float in_range = step(0.32, r) * smoothstep(0.4, 0.38, r);
        ticks += smoothstep(0.02, 0.008, diff) * in_range;
    }
    
    // Gnomon shadow (pointing to ~10 o'clock)
    float shadow_angle = -1.5708 + 10.0 * 0.5236;
    vec2 shadow_dir = vec2(cos(shadow_angle), sin(shadow_angle));
    float shadow_proj = dot(p, shadow_dir);
    float shadow_perp = abs(dot(p, vec2(-shadow_dir.y, shadow_dir.x)));
    float shadow = smoothstep(0.015, 0.005, shadow_perp) * step(0.0, shadow_proj) * smoothstep(0.38, 0.36, r);
    
    // Roman numerals (simplified as dots)
    vec3 dial_col = vec3(0.85, 0.8, 0.7);
    vec3 col = vec3(0.4, 0.5, 0.6);
    col = mix(col, dial_col, dial);
    col = mix(col, vec3(0.5, 0.45, 0.35), rim);
    col = mix(col, vec3(0.2), min(markers, 1.0) * dial);
    col = mix(col, vec3(0.3), min(ticks, 1.0) * dial);
    col = mix(col, vec3(0.4, 0.38, 0.35) * 0.6, shadow);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

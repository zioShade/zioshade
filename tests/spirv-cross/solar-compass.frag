#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test compass / solar compass pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Compass face
    float face = smoothstep(0.42, 0.4, r);
    float rim = smoothstep(0.42, 0.41, r) * (1.0 - smoothstep(0.39, 0.38, r));
    
    // Degree ticks
    float ticks = 0.0;
    for (int i = 0; i < 36; i++) {
        float ta = float(i) * 0.17453 - 1.5708;
        float diff = abs(a - ta);
        diff = min(diff, 6.2832 - diff);
        float inner = 0.32;
        float outer = 0.38;
        ticks += smoothstep(0.03, 0.015, diff) * step(inner, r) * smoothstep(outer + 0.01, outer, r);
    }
    
    // Cardinal direction ticks (longer)
    float card_ticks = 0.0;
    float card_angles[4];
    card_angles[0] = -1.5708; // N
    card_angles[1] = 0.0;     // E
    card_angles[2] = 1.5708;  // S
    card_angles[3] = 3.1416;  // W
    for (int i = 0; i < 4; i++) {
        float diff = abs(a - card_angles[i]);
        diff = min(diff, 6.2832 - diff);
        card_ticks += smoothstep(0.04, 0.02, diff) * step(0.25, r) * smoothstep(0.39, 0.37, r);
    }
    
    // Needle pointing north
    float needle_a = -1.5708;
    vec2 needle_dir = vec2(cos(needle_a), sin(needle_a));
    float needle_proj = dot(p, needle_dir);
    float needle_perp = abs(dot(p, vec2(-needle_dir.y, needle_dir.x)));
    float north_needle = smoothstep(0.012, 0.005, needle_perp) * step(0.0, needle_proj) * smoothstep(0.35, 0.33, needle_proj);
    float south_needle = smoothstep(0.012, 0.005, needle_perp) * step(needle_proj, 0.0) * smoothstep(0.12, 0.1, -needle_proj);
    
    // Center pin
    float pin = smoothstep(0.025, 0.02, r);
    
    vec3 face_col = vec3(0.95, 0.92, 0.85);
    vec3 rim_col = vec3(0.6, 0.55, 0.45);
    vec3 tick_col = vec3(0.2);
    vec3 north_col = vec3(0.85, 0.15, 0.1);
    vec3 south_col = vec3(0.3, 0.3, 0.35);
    
    vec3 col = vec3(0.15, 0.2, 0.15); // background
    col = mix(col, face_col, face);
    col = mix(col, rim_col, rim);
    col = mix(col, tick_col, min(ticks, 1.0) * face);
    col = mix(col, tick_col, min(card_ticks, 1.0) * face);
    col = mix(col, north_col, north_needle);
    col = mix(col, south_col, south_needle);
    col = mix(col, vec3(0.5, 0.45, 0.4), pin);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

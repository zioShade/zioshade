#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test suspension bridge pattern
void main() {
    vec3 col = vec3(0.45, 0.6, 0.85); // sky
    
    // Water below
    float water_line = 0.35;
    float water = step(uv.y, water_line);
    vec3 water_col = vec3(0.15, 0.25, 0.45);
    col = mix(col, water_col, water);
    
    // Water reflection lines
    float wave = sin(uv.x * 40.0) * 0.005;
    float refl = smoothstep(0.003, 0.001, abs(uv.y - (water_line - 0.03 + wave)));
    col += refl * vec3(0.2, 0.3, 0.5) * water;
    
    // Bridge deck
    float deck_y = 0.4;
    float deck = smoothstep(0.015, 0.01, abs(uv.y - deck_y)) * step(0.05, uv.x) * step(uv.x, 0.95);
    col = mix(col, vec3(0.35, 0.3, 0.25), deck);
    
    // Road surface on top of deck
    float road = smoothstep(0.005, 0.002, deck_y - uv.y) * step(uv.y, deck_y) * step(0.05, uv.x) * step(uv.x, 0.95);
    col = mix(col, vec3(0.25, 0.25, 0.28), road);
    
    // Towers
    float tower_w = 0.02;
    float tower1 = smoothstep(tower_w, tower_w - 0.005, abs(uv.x - 0.25)) * step(deck_y - 0.02, uv.y) * smoothstep(0.78, 0.76, uv.y);
    float tower2 = smoothstep(tower_w, tower_w - 0.005, abs(uv.x - 0.75)) * step(deck_y - 0.02, uv.y) * smoothstep(0.78, 0.76, uv.y);
    col = mix(col, vec3(0.5, 0.48, 0.45), max(tower1, tower2));
    
    // Main cables (catenary curves)
    float cable_left = 0.25 * (1.0 - uv.x / 0.25) + 0.76 * (uv.x / 0.25);
    float cable_mid_l = 0.76 - 0.15 * sin(uv.x / 0.5 * 3.14159);
    float cable_mid_r = 0.76 - 0.15 * sin((uv.x - 0.5) / 0.5 * 3.14159);
    
    float cable_y = uv.y;
    if (uv.x < 0.25) cable_y = uv.y - (0.76 - (0.76 - deck_y - 0.05) * (uv.x / 0.25) * (uv.x / 0.25));
    else if (uv.x < 0.75) cable_y = uv.y - (0.61 + 0.15 * sin((uv.x - 0.25) / 0.5 * 3.14159));
    else cable_y = uv.y - (0.76 - (0.76 - deck_y - 0.05) * ((1.0 - uv.x) / 0.25) * ((1.0 - uv.x) / 0.25));
    
    float main_cable = smoothstep(0.005, 0.002, abs(cable_y));
    col += main_cable * vec3(0.3);
    
    // Vertical suspender cables
    float suspenders = 0.0;
    for (int i = 1; i < 10; i++) {
        float sx = 0.05 + float(i) * 0.1;
        if (sx > 0.2 && sx < 0.3) continue;
        if (sx > 0.7 && sx < 0.8) continue;
        float susp = smoothstep(0.003, 0.001, abs(uv.x - sx));
        susp *= step(deck_y + 0.01, uv.y) * smoothstep(deck_y + 0.01, deck_y + 0.03, uv.y);
        suspenders += susp;
    }
    col += suspenders * vec3(0.25);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

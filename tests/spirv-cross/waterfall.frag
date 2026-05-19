#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test waterfall with mist and rocks
void main() {
    vec3 col;
    
    // Sky
    col = mix(vec3(0.4, 0.6, 0.8), vec3(0.2, 0.35, 0.6), uv.y);
    
    // Cliff face (left and right walls)
    float cliff_l = smoothstep(0.15, 0.13, uv.x) * step(0.3, uv.y);
    float cliff_r = smoothstep(0.15, 0.13, 1.0 - uv.x) * step(0.3, uv.y);
    vec3 rock = vec3(0.35, 0.3, 0.25);
    col = mix(col, rock, max(cliff_l, cliff_r));
    
    // Waterfall stream (center column)
    float fall_x = smoothstep(0.03, 0.02, abs(uv.x - 0.5));
    float fall_top = step(0.45, uv.y) * smoothstep(0.95, 0.9, uv.y);
    float fall_mid = step(0.15, uv.y) * smoothstep(0.45, 0.4, uv.y);
    float waterfall = fall_x * (fall_top + fall_mid);
    
    // Water texture (horizontal streaks)
    float streak = sin(uv.y * 80.0) * 0.5 + 0.5;
    vec3 water = vec3(0.7, 0.8, 0.9) * (0.8 + streak * 0.2);
    col = mix(col, water, waterfall);
    
    // Mist at base
    float mist_y = smoothstep(0.2, 0.15, uv.y) * step(0.05, uv.y);
    float mist_x = exp(-abs(uv.x - 0.5) * 6.0);
    float mist = mist_y * mist_x * 0.6;
    col = mix(col, vec3(0.8, 0.85, 0.9), mist);
    
    // Splash particles
    float splash = 0.0;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float sx = 0.5 + sin(fi * 3.7) * 0.08;
        float sy = 0.13 + fi * 0.015;
        float sd = length(uv - vec2(sx, sy));
        splash += smoothstep(0.01, 0.005, sd);
    }
    col += splash * vec3(0.5, 0.7, 0.9) * mist_y;
    
    // Pool at bottom
    float pool = step(uv.y, 0.1) * step(0.1, uv.y);
    vec3 pool_col = vec3(0.15, 0.3, 0.5);
    float ripple = sin(uv.x * 20.0 + uv.y * 5.0) * 0.02;
    col = mix(col, pool_col + ripple, step(uv.y, 0.12));
    
    // Rocks at base
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float rx = 0.15 + fi * 0.17;
        float ry = 0.1 + sin(fi * 2.3) * 0.03;
        float rd = length((uv - vec2(rx, ry)) * vec2(1.0, 0.7));
        float rock_shape = smoothstep(0.04, 0.03, rd);
        col = mix(col, rock * 0.8, rock_shape);
    }
    
    // Vegetation on cliffs
    float veg_l = step(0.1, uv.x) * smoothstep(0.13, 0.12, uv.x) * step(0.5, uv.y);
    float veg_r = step(uv.x, 0.9) * smoothstep(0.87, 0.88, uv.x) * step(0.5, uv.y);
    col += (veg_l + veg_r) * vec3(0.1, 0.3, 0.1);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

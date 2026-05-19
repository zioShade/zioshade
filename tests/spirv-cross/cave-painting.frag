#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test cave painting / pictograph style
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    // Rock wall background
    float tex1 = hash(floor(uv * 80.0));
    float tex2 = hash(floor(uv * 40.0 + 100.0));
    vec3 rock = vec3(0.55, 0.45, 0.35) + (tex1 * 0.08 - 0.04) + (tex2 * 0.05);
    
    // Mineral streaks
    float streak = sin(uv.x * 20.0 + uv.y * 5.0) * 0.03;
    rock += streak;
    
    vec3 col = rock;
    
    // Paint pigment (red ochre)
    vec3 ochre = vec3(0.65, 0.25, 0.1);
    vec3 charcoal = vec3(0.12, 0.1, 0.08);
    vec3 white_paint = vec3(0.8, 0.78, 0.72);
    
    // Hand print (negative: sprayed around hand)
    vec2 hp = uv - vec2(0.25, 0.55);
    float hand_d = length(hp * vec2(0.8, 1.0));
    float palm = smoothstep(0.1, 0.08, hand_d);
    
    // Fingers
    float fingers = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float angle = -0.5 + fi * 0.25;
        vec2 fdir = vec2(sin(angle), cos(angle));
        float proj = dot(hp, fdir);
        float perp = abs(dot(hp, vec2(-fdir.y, fdir.x)));
        float f = smoothstep(0.022, 0.015, perp) * step(0.08, proj) * smoothstep(0.18, 0.16, proj);
        fingers += f;
    }
    
    float hand = max(palm, min(fingers, 1.0));
    // Spray around hand (not inside)
    float spray_area = smoothstep(0.05, 0.15, hand_d) * (1.0 - smoothstep(0.15, 0.2, hand_d));
    float spray = spray_area * step(0.5, hash(floor(uv * 60.0)));
    col = mix(col, ochre, spray * 0.7);
    
    // Animal silhouette (simplified deer)
    vec2 dp = uv - vec2(0.65, 0.5);
    float body = smoothstep(0.06, 0.05, abs(dp.y)) * step(0.0, dp.x) * smoothstep(0.2, 0.18, dp.x);
    float head = smoothstep(0.025, 0.02, length(dp - vec2(0.2, 0.02)));
    // Legs
    float leg1 = smoothstep(0.006, 0.003, abs(dp.x - 0.04)) * step(-0.1, dp.y) * step(dp.y, -0.04);
    float leg2 = smoothstep(0.006, 0.003, abs(dp.x - 0.14)) * step(-0.1, dp.y) * step(dp.y, -0.04);
    // Antlers
    float ant1 = smoothstep(0.005, 0.002, abs((dp.x - 0.22) - (dp.y - 0.02) * 0.5)) * step(0.02, dp.y) * step(dp.x, 0.28);
    float ant2 = smoothstep(0.005, 0.002, abs((dp.x - 0.22) + (dp.y - 0.02) * 0.5)) * step(0.02, dp.y) * step(dp.x, 0.28);
    
    float animal = max(max(body, head), max(max(leg1, leg2), max(ant1, ant2)));
    col = mix(col, charcoal, animal);
    
    // Sun symbol (circle with rays)
    vec2 sp = uv - vec2(0.5, 0.82);
    float sr = length(sp);
    float sun_circle = smoothstep(0.04, 0.035, sr);
    float sun_rays = 0.0;
    for (int i = 0; i < 8; i++) {
        float fa = float(i) * 0.7854;
        float diff = abs(atan(sp.y, sp.x) - fa);
        diff = min(diff, 6.2832 - diff);
        sun_rays += smoothstep(0.1, 0.04, diff) * step(0.04, sr) * smoothstep(0.09, 0.08, sr);
    }
    col = mix(col, ochre, max(sun_circle, min(sun_rays, 1.0)));
    
    // Dots pattern
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        vec2 dot_pos = vec2(0.1 + fi * 0.1, 0.2);
        float dd = length(uv - dot_pos);
        float dot = smoothstep(0.012, 0.008, dd);
        col = mix(col, ochre, dot);
    }
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

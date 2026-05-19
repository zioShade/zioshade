#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test glacier landscape with ice and crevasses
void main() {
    vec3 col;
    
    // Sky: cold blue gradient
    col = mix(vec3(0.6, 0.7, 0.85), vec3(0.25, 0.35, 0.55), uv.y);
    
    // Mountains in background
    float mt1 = smoothstep(0.0, 0.08, uv.y - (0.5 - abs(uv.x - 0.3) * 0.8));
    float mt2 = smoothstep(0.0, 0.06, uv.y - (0.45 - abs(uv.x - 0.7) * 0.6));
    vec3 mountain = vec3(0.35, 0.4, 0.5);
    col = mix(col, mountain, max(mt1, mt2) * smoothstep(0.4, 0.5, uv.y));
    
    // Snow caps
    float snow = smoothstep(0.0, 0.02, uv.y - (0.55 - abs(uv.x - 0.3) * 0.5));
    col = mix(col, vec3(0.9, 0.92, 0.95), (1.0 - snow) * mt1);
    
    // Glacier body
    float glacier_top = 0.4 + 0.03 * sin(uv.x * 4.0);
    float glacier = smoothstep(glacier_top, glacier_top - 0.01, uv.y);
    
    vec3 ice = vec3(0.75, 0.85, 0.95);
    vec3 ice_deep = vec3(0.4, 0.6, 0.85);
    float depth = smoothstep(0.3, 0.1, uv.y);
    vec3 ice_col = mix(ice, ice_deep, depth);
    col = mix(col, ice_col, glacier);
    
    // Crevasses
    float crevasse = 0.0;
    crevasse += smoothstep(0.008, 0.002, abs(uv.x - 0.3)) * glacier * step(0.1, uv.y);
    crevasse += smoothstep(0.006, 0.002, abs(uv.x - 0.55)) * glacier * step(0.15, uv.y);
    crevasse += smoothstep(0.005, 0.001, abs(uv.x - 0.72)) * glacier * step(0.12, uv.y);
    col = mix(col, vec3(0.1, 0.15, 0.25), crevasse);
    
    // Ice texture
    float tex = sin(uv.x * 50.0 + uv.y * 30.0) * 0.03;
    col += tex * glacier;
    
    // Water
    float water = step(uv.y, 0.08);
    vec3 water_col = vec3(0.15, 0.3, 0.5);
    float reflection = sin(uv.x * 20.0) * 0.02;
    col = mix(col, water_col + reflection, water);
    
    // Icebergs
    float berg1 = smoothstep(0.03, 0.025, length((uv - vec2(0.2, 0.06)) * vec2(1.0, 1.5)));
    float berg2 = smoothstep(0.025, 0.02, length((uv - vec2(0.5, 0.055)) * vec2(1.0, 1.5)));
    float berg3 = smoothstep(0.035, 0.03, length((uv - vec2(0.78, 0.065)) * vec2(1.0, 1.5)));
    col = mix(col, ice * 0.9, (berg1 + berg2 + berg3) * water);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

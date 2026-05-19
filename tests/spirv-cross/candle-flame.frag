#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test candle with flickering flame
void main() {
    vec2 p = uv;
    
    // Background: dark room
    vec3 col = vec3(0.02, 0.02, 0.03);
    
    // Candle body
    float candle_left = smoothstep(0.01, 0.005, abs(uv.x - 0.5)) * step(0.15, uv.y) * step(uv.y, 0.6);
    float candle_w = smoothstep(0.015, 0.01, abs(uv.x - (0.5 + (uv.y - 0.15) * 0.02)));
    candle_w *= step(0.15, uv.y) * step(uv.y, 0.6);
    vec3 wax = vec3(0.9, 0.88, 0.8);
    col = mix(col, wax, candle_w);
    
    // Wick
    float wick = smoothstep(0.003, 0.001, abs(uv.x - 0.5)) * step(0.58, uv.y) * step(uv.y, 0.64);
    col = mix(col, vec3(0.15), wick);
    
    // Flame (teardrop shape)
    vec2 fp = uv - vec2(0.5, 0.7);
    float fr = length(fp * vec2(1.0, 0.7));
    float fa = atan(fp.x, fp.y);
    float flame_shape = 0.1 - abs(fp.y) * 0.4 - fr * 0.3;
    float flame = smoothstep(0.0, 0.02, flame_shape);
    
    // Flame colors: white core -> yellow -> orange -> red tip
    float t = smoothstep(0.06, 0.0, fr);
    vec3 flame_core = vec3(1.0, 0.95, 0.9);
    vec3 flame_mid = vec3(1.0, 0.7, 0.15);
    vec3 flame_outer = vec3(0.9, 0.3, 0.05);
    vec3 flame_col = mix(flame_outer, flame_mid, t);
    flame_col = mix(flame_col, flame_core, t * t);
    
    col = mix(col, flame_col, flame);
    
    // Glow
    float glow = exp(-length(uv - vec2(0.5, 0.7)) * 4.0) * 0.15;
    col += glow * vec3(1.0, 0.7, 0.3);
    
    // Holder / base
    float base = smoothstep(0.06, 0.04, abs(uv.y - 0.15)) * step(0.35, uv.x) * step(uv.x, 0.65);
    float base_rim = smoothstep(0.03, 0.01, abs(uv.y - 0.12)) * step(0.3, uv.x) * step(uv.x, 0.7);
    col = mix(col, vec3(0.4, 0.35, 0.3), max(base, base_rim));
    
    // Surface reflection on table
    float table = step(uv.y, 0.08);
    float refl_glow = exp(-length(vec2(uv.x - 0.5, uv.y - 0.08) * vec2(1.0, 3.0)) * 5.0) * 0.08;
    col = mix(col, vec3(0.1, 0.08, 0.05), table);
    col += refl_glow * vec3(1.0, 0.6, 0.2) * table;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

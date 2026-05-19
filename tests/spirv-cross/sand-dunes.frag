#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test desert sand dunes pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec3 col;
    
    // Sky gradient
    vec3 sky_top = vec3(0.3, 0.55, 0.85);
    vec3 sky_horizon = vec3(0.85, 0.75, 0.5);
    float sky_mask = smoothstep(0.4, 0.55, uv.y);
    col = mix(sky_horizon, sky_top, sky_mask);
    
    // Sun
    float sun_d = length(uv - vec2(0.7, 0.65));
    float sun = smoothstep(0.06, 0.05, sun_d);
    float sun_glow = exp(-sun_d * 8.0) * 0.15;
    col += sun * vec3(1.0, 0.95, 0.8);
    col += sun_glow * vec3(1.0, 0.8, 0.4);
    
    // Sand dunes (multiple overlapping sine waves)
    float dune1 = 0.35 + 0.06 * sin(uv.x * 3.0 + 0.5);
    float dune2 = 0.28 + 0.04 * sin(uv.x * 5.0 + 2.0);
    float dune3 = 0.22 + 0.03 * sin(uv.x * 8.0 + 1.0);
    
    float is_dune1 = smoothstep(dune1, dune1 - 0.005, uv.y);
    float is_dune2 = step(uv.y, dune2) * (1.0 - is_dune1);
    float is_dune3 = step(uv.y, dune3);
    
    // Sand colors with shading
    vec3 sand_light = vec3(0.85, 0.75, 0.55);
    vec3 sand_mid = vec3(0.75, 0.62, 0.4);
    vec3 sand_dark = vec3(0.6, 0.5, 0.3);
    
    // Shade based on slope
    float slope1 = cos(uv.x * 3.0 + 0.5);
    float shade1 = 0.7 + 0.3 * step(0.0, slope1);
    
    col = mix(col, sand_light * shade1, is_dune1);
    col = mix(col, sand_mid, is_dune2);
    col = mix(col, sand_dark, is_dune3);
    
    // Sand texture (subtle noise)
    float tex = hash(floor(uv * 100.0)) * 0.04;
    col += tex * (1.0 - sky_mask);
    
    // Heat haze near horizon
    float haze = smoothstep(0.3, 0.4, uv.y) * (1.0 - smoothstep(0.4, 0.5, uv.y));
    col = mix(col, vec3(0.85, 0.8, 0.6), haze * 0.3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

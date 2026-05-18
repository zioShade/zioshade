#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test star constellation map
void main() {
    vec3 col = vec3(0.01, 0.01, 0.04);
    
    // Background stars (random dots)
    float star_hash = fract(sin(dot(floor(uv * 200.0), vec2(127.1, 311.7))) * 43758.5);
    float star_brightness = step(0.997, star_hash);
    vec2 star_offset = vec2(fract(star_hash * 13.7), fract(star_hash * 7.3));
    float star_d = length(fract(uv * 200.0) - star_offset);
    float star = smoothstep(0.1, 0.0, star_d) * star_brightness;
    col += star * vec3(0.8, 0.85, 1.0);
    
    // Constellation stars (brighter, at specific positions)
    float s1 = smoothstep(0.015, 0.005, length(uv - vec2(0.2, 0.7)));
    float s2 = smoothstep(0.015, 0.005, length(uv - vec2(0.35, 0.65)));
    float s3 = smoothstep(0.015, 0.005, length(uv - vec2(0.45, 0.75)));
    float s4 = smoothstep(0.015, 0.005, length(uv - vec2(0.6, 0.6)));
    float s5 = smoothstep(0.015, 0.005, length(uv - vec2(0.75, 0.7)));
    
    col += (s1 + s2 + s3 + s4 + s5) * vec3(1.0, 0.95, 0.7);
    
    // Constellation lines (approximate with distance to line segments)
    float line12 = 0.0; { vec2 a = vec2(0.2, 0.7); vec2 b = vec2(0.35, 0.65); float t = clamp(dot(uv - a, b - a) / dot(b - a, b - a), 0.0, 1.0); line12 = smoothstep(0.003, 0.0, length(uv - a - (b - a) * t)); }
    float line23 = 0.0; { vec2 a = vec2(0.35, 0.65); vec2 b = vec2(0.45, 0.75); float t = clamp(dot(uv - a, b - a) / dot(b - a, b - a), 0.0, 1.0); line23 = smoothstep(0.003, 0.0, length(uv - a - (b - a) * t)); }
    float line34 = 0.0; { vec2 a = vec2(0.45, 0.75); vec2 b = vec2(0.6, 0.6); float t = clamp(dot(uv - a, b - a) / dot(b - a, b - a), 0.0, 1.0); line34 = smoothstep(0.003, 0.0, length(uv - a - (b - a) * t)); }
    float line45 = 0.0; { vec2 a = vec2(0.6, 0.6); vec2 b = vec2(0.75, 0.7); float t = clamp(dot(uv - a, b - a) / dot(b - a, b - a), 0.0, 1.0); line45 = smoothstep(0.003, 0.0, length(uv - a - (b - a) * t)); }
    
    col += (line12 + line23 + line34 + line45) * vec3(0.3, 0.4, 0.6);
    
    fragColor = vec4(col, 1.0);
}

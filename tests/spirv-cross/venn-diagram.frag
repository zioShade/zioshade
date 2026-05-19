#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Venn diagram with 3 overlapping circles
void main() {
    vec3 col = vec3(0.98, 0.97, 0.96);
    
    vec2 c1 = vec2(0.38, 0.52);
    vec2 c2 = vec2(0.62, 0.52);
    vec2 c3 = vec2(0.5, 0.68);
    float rad = 0.17;
    
    float d1 = length(uv - c1);
    float d2 = length(uv - c2);
    float d3 = length(uv - c3);
    
    // Filled circles with transparency
    float circle1 = smoothstep(rad, rad - 0.003, d1);
    float circle2 = smoothstep(rad, rad - 0.003, d2);
    float circle3 = smoothstep(rad, rad - 0.003, d3);
    
    vec3 red = vec3(0.9, 0.2, 0.15);
    vec3 blue = vec3(0.15, 0.3, 0.85);
    vec3 green = vec3(0.1, 0.7, 0.2);
    
    // Additive-like blending
    col += circle1 * red * 0.4;
    col += circle2 * blue * 0.4;
    col += circle3 * green * 0.4;
    
    // Overlap regions appear brighter/mixed
    float overlap12 = circle1 * circle2;
    float overlap13 = circle1 * circle3;
    float overlap23 = circle2 * circle3;
    float overlap123 = circle1 * circle2 * circle3;
    
    col += overlap12 * vec3(0.3, 0.15, 0.3) * 0.5;
    col += overlap13 * vec3(0.3, 0.3, 0.1) * 0.5;
    col += overlap23 * vec3(0.1, 0.3, 0.3) * 0.5;
    col += overlap123 * vec3(0.2, 0.15, 0.15);
    
    // Circle outlines
    float outline1 = smoothstep(0.005, 0.002, abs(d1 - rad));
    float outline2 = smoothstep(0.005, 0.002, abs(d2 - rad));
    float outline3 = smoothstep(0.005, 0.002, abs(d3 - rad));
    col = mix(col, vec3(0.2), (outline1 + outline2 + outline3) * 0.7);
    
    // Center label dot
    float center = smoothstep(0.01, 0.005, length(uv - vec2(0.5, 0.57)));
    col = mix(col, vec3(0.1), center);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

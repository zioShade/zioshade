#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test aurora borealis effect
void main() {
    // Sky gradient
    vec3 sky_low = vec3(0.02, 0.02, 0.08);
    vec3 sky_high = vec3(0.02, 0.04, 0.12);
    vec3 sky = mix(sky_low, sky_high, uv.y);
    
    // Aurora curtain layers
    float curtain1 = sin(uv.x * 6.0 + sin(uv.y * 3.0) * 2.0) * 0.5 + 0.5;
    float curtain2 = sin(uv.x * 8.0 - sin(uv.y * 2.5 + 1.0) * 1.5) * 0.5 + 0.5;
    float curtain3 = sin(uv.x * 5.0 + sin(uv.y * 4.0 + 2.0) * 1.0) * 0.5 + 0.5;
    
    // Vertical falloff
    float v1 = smoothstep(0.3, 0.5, uv.y) * (1.0 - smoothstep(0.7, 0.9, uv.y));
    float v2 = smoothstep(0.4, 0.55, uv.y) * (1.0 - smoothstep(0.75, 0.95, uv.y));
    float v3 = smoothstep(0.35, 0.45, uv.y) * (1.0 - smoothstep(0.65, 0.85, uv.y));
    
    // Aurora colors
    vec3 green = vec3(0.1, 0.8, 0.3);
    vec3 blue = vec3(0.1, 0.3, 0.9);
    vec3 purple = vec3(0.6, 0.2, 0.8);
    
    vec3 aurora = vec3(0.0);
    aurora += green * curtain1 * v1 * 0.4;
    aurora += blue * curtain2 * v2 * 0.25;
    aurora += purple * curtain3 * v3 * 0.2;
    
    vec3 col = sky + aurora;
    
    // Ground silhouette
    float ground = smoothstep(0.15, 0.12, uv.y);
    col = mix(col, vec3(0.01), ground);
    
    // Stars
    float star = step(0.998, fract(sin(dot(floor(uv * 300.0), vec2(12.9, 78.2))) * 43758.5));
    col += star * vec3(0.8) * (1.0 - ground) * (1.0 - aurora.r * 3.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

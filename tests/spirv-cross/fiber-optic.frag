#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test fiber optic light transmission
void main() {
    vec2 p = uv * 20.0;
    vec2 id = floor(p);
    vec2 fp = fract(p) - 0.5;
    
    float r = length(fp);
    
    // Fiber core
    float core = smoothstep(0.3, 0.25, r);
    float cladding = smoothstep(0.4, 0.35, r) * (1.0 - core);
    
    // Color based on fiber position
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    vec3 core_color = 0.5 + 0.5 * cos(6.28 * (h + vec3(0.0, 0.33, 0.67)));
    
    vec3 col = vec3(0.02);
    col += cladding * vec3(0.15);
    col += core * core_color * 0.8;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

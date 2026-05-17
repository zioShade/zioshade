#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test domain repetition with offset
void main() {
    vec2 p = uv * 6.0;
    vec2 id = floor(p);
    p = fract(p) - 0.5;
    
    // Different shape per cell
    float shape = 0.0;
    float cx = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    float cy = fract(sin(dot(id, vec2(269.5, 183.3))) * 43758.5);
    
    vec2 offset = vec2(cx, cy) - 0.5;
    float d = length(p - offset * 0.3);
    
    shape = smoothstep(0.3, 0.28, d);
    
    vec3 col = shape * vec3(cx, cy, 0.5);
    fragColor = vec4(clamp(col + 0.05, 0.0, 1.0), 1.0);
}

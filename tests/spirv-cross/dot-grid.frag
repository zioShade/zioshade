#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test dot pattern with varying radius
void main() {
    vec2 p = uv * 10.0;
    vec2 id = floor(p);
    vec2 fp = fract(p) - 0.5;
    
    float r = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    float d = length(fp);
    
    float dot_val = smoothstep(r * 0.3 + 0.1, r * 0.3 + 0.08, d);
    
    vec3 col = dot_val * vec3(r, 1.0 - r, 0.5);
    fragColor = vec4(clamp(col + 0.02, 0.0, 1.0), 1.0);
}

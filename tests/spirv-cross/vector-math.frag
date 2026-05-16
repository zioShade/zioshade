#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test length, distance, normalize, dot across vectors
void main() {
    vec2 a = uv * 2.0 - 1.0;
    vec2 b = vec2(0.5, -0.3);
    
    float len_a = length(a);
    float dist_ab = distance(a, b);
    vec2 norm_a = normalize(a + vec2(0.001));
    float dot_ab = dot(a, b);
    
    float r = clamp(len_a, 0.0, 1.0);
    float g = clamp(dist_ab * 0.5, 0.0, 1.0);
    float bval = clamp(dot_ab + 0.5, 0.0, 1.0);
    
    fragColor = vec4(r, g, bval, 1.0);
}

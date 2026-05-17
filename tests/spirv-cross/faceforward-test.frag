#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test faceforward with edge cases
void main() {
    vec3 N = vec3(0.0, 0.0, 1.0);
    vec3 I = vec3(uv.x - 0.5, uv.y - 0.5, -0.5);
    
    // faceforward flips I if it faces same direction as N
    vec3 ff = faceforward(I, N, N);
    
    // reflect the faceforward result
    vec3 refl = reflect(normalize(ff), N);
    
    float r = refl.x * 0.5 + 0.5;
    float g = refl.y * 0.5 + 0.5;
    float b = dot(ff, N) * 0.5 + 0.5;
    
    fragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
}

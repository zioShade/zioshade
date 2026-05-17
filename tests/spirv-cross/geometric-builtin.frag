#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test geometric builtins comprehensively
void main() {
    vec3 a = vec3(uv.x, 0.0, uv.y);
    vec3 b = vec3(0.0, uv.y, uv.x);
    
    float d = distance(a, b);
    float l = length(a);
    vec3 n = normalize(a + b + vec3(0.001));
    
    // Reflect and refract
    vec3 I = normalize(a);
    vec3 N = vec3(0.0, 1.0, 0.0);
    vec3 refl = reflect(I, N);
    vec3 refr = refract(I, N, 0.9);
    
    vec3 col = vec3(
        clamp(d * 0.5, 0.0, 1.0),
        clamp(l * 0.5, 0.0, 1.0),
        clamp(dot(refl, refr) * 0.5 + 0.5, 0.0, 1.0)
    );
    
    fragColor = vec4(col, 1.0);
}

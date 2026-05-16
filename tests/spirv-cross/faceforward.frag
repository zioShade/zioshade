#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test faceforward, reflect, refract
void main() {
    vec3 N = vec3(0.0, 0.0, 1.0);
    vec3 I = normalize(vec3(uv * 2.0 - 1.0, -0.5));
    
    vec3 ff = faceforward(N, I, N);
    vec3 refl = reflect(I, N);
    vec3 refr = refract(I, N, 0.9);
    
    float r = refl.x * 0.5 + 0.5;
    float g = refr.y * 0.5 + 0.5;
    float b = ff.z * 0.5 + 0.5;
    
    fragColor = vec4(r, g, b, 1.0);
}

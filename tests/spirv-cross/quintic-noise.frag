#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Gradient noise with smooth interpolation
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    
    // Quintic interpolation
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void main() {
    float n = vnoise(uv * 5.0);
    
    // Contrast stretch
    n = smoothstep(0.2, 0.8, n);
    
    vec3 col = mix(vec3(0.1, 0.15, 0.2), vec3(0.9, 0.7, 0.5), n);
    fragColor = vec4(col, 1.0);
}

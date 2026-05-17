#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test camouflage pattern with layered noise
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1,0)), f.x),
               mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), f.x), f.y);
}

void main() {
    float n1 = noise(uv * 6.0);
    float n2 = noise(uv * 12.0 + 10.0);
    float n3 = noise(uv * 3.0 + 20.0);
    
    float n = n1 * 0.5 + n2 * 0.3 + n3 * 0.2;
    
    vec3 green1 = vec3(0.2, 0.35, 0.15);
    vec3 green2 = vec3(0.3, 0.45, 0.2);
    vec3 brown = vec3(0.4, 0.3, 0.15);
    vec3 dark = vec3(0.15, 0.2, 0.1);
    
    vec3 col;
    if (n < 0.3) col = dark;
    else if (n < 0.5) col = green1;
    else if (n < 0.7) col = brown;
    else col = green2;
    
    fragColor = vec4(col, 1.0);
}

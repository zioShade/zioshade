#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test nebula with multiple noise layers
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
    float n1 = noise(uv * 3.0);
    float n2 = noise(uv * 6.0 + 10.0);
    float n3 = noise(uv * 12.0 + 20.0);
    
    float density = n1 * 0.5 + n2 * 0.3 + n3 * 0.2;
    
    vec3 deep = vec3(0.02, 0.01, 0.05);
    vec3 dust = vec3(0.3, 0.1, 0.4);
    vec3 bright = vec3(0.6, 0.3, 0.8);
    vec3 stars = vec3(0.9, 0.9, 1.0);
    
    vec3 col = deep;
    col = mix(col, dust, smoothstep(0.3, 0.6, density));
    col = mix(col, bright, smoothstep(0.6, 0.8, density));
    
    // Random stars
    float star_hash = hash(floor(uv * 100.0));
    col += stars * step(0.998, star_hash);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

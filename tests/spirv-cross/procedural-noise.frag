#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Procedural noise pattern - exercises math builtins, loops, mixing
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void main() {
    float n = noise(uv * 8.0);
    n += 0.5 * noise(uv * 16.0);
    n += 0.25 * noise(uv * 32.0);
    n /= 1.75;
    
    vec3 color = mix(vec3(0.2, 0.3, 0.5), vec3(0.8, 0.9, 1.0), n);
    fragColor = vec4(color, 1.0);
}

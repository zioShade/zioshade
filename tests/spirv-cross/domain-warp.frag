#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

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
    // Domain warping
    vec2 p = uv * 3.0;
    float n1 = noise(p);
    float n2 = noise(p + vec2(n1 * 2.0));
    float n3 = noise(p + vec2(n2 * 2.0));

    float r = noise(p + vec2(n3 * 3.0 + 0.0));
    float g = noise(p + vec2(n3 * 3.0 + 5.2));
    float b = noise(p + vec2(n3 * 3.0 + 1.3));

    fragColor = vec4(r, g, b, 1.0);
}

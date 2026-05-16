#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Gradient noise with different octaves
    float n = 0.0;
    float amp = 0.5;
    float freq = 1.0;

    for (int i = 0; i < 6; i++) {
        vec2 p = uv * freq;
        vec2 f = fract(p);
        vec2 i = floor(p);

        float a = fract(sin(dot(i, vec2(127.1, 311.7))) * 43758.5);
        float b = fract(sin(dot(i + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5);
        float c = fract(sin(dot(i + vec2(0.0, 1.0), vec2(127.1, 311.7))) * 43758.5);
        float d = fract(sin(dot(i + vec2(1.0, 1.0), vec2(127.1, 311.7))) * 43758.5);

        f = f * f * (3.0 - 2.0 * f);
        float val = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);

        n += val * amp;
        amp *= 0.5;
        freq *= 2.0;
    }

    vec3 col = vec3(n);
    fragColor = vec4(col, 1.0);
}

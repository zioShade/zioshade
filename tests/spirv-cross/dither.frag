#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

float random(vec2 st) {
    return fract(sin(dot(st, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
    // Dithering pattern
    float gray = uv.x * 0.5 + uv.y * 0.5;
    float noise = random(uv * 100.0);

    float dithered = step(noise, gray);

    vec3 col = vec3(dithered);
    fragColor = vec4(col, 1.0);
}

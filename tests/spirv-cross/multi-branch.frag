#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

float noise(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    // Test function with multiple return paths
    vec2 cell = floor(uv * 8.0);
    float n = noise(cell);
    vec3 color;
    if (n > 0.75) {
        color = vec3(0.9, 0.2, 0.1);
    } else if (n > 0.5) {
        color = vec3(0.1, 0.8, 0.3);
    } else if (n > 0.25) {
        color = vec3(0.2, 0.3, 0.9);
    } else {
        color = vec3(0.8, 0.7, 0.1);
    }
    float brightness = 0.7 + 0.3 * noise(uv * 16.0);
    fragColor = vec4(color * brightness, 1.0);
}

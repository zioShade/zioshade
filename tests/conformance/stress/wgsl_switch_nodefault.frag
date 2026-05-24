#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    int x = int(uv.x * 8.0);
    vec3 color = vec3(0.2);

    // Switch without explicit default
    switch (x) {
        case 0: color = vec3(1.0, 0.0, 0.0); break;
        case 1: color = vec3(0.0, 1.0, 0.0); break;
        case 2: color = vec3(0.0, 0.0, 1.0); break;
    }

    // Switch with explicit default
    int y = int(uv.y * 4.0);
    switch (y) {
        case 0: color *= 0.5; break;
        case 1: color *= 1.5; break;
        default: color *= 0.8; break;
    }

    fragColor = vec4(color, 1.0);
}

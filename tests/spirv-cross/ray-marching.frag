#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Simple ray marching
    vec2 p = uv * 2.0 - 1.0;
    float d = 1.0;
    float t = 0.0;

    for (int i = 0; i < 16; i++) {
        vec2 pos = p * t;
        d = length(pos) - 0.5;
        if (d < 0.01) break;
        t += d;
        if (t > 5.0) break;
    }

    float col = 1.0 / (1.0 + t * 0.5);
    vec3 color = vec3(col * 0.8, col * 0.6, col);

    fragColor = vec4(color, 1.0);
}

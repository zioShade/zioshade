#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 color = vec3(0.0);
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float d = length(uv - vec2(fi * 0.1 + 0.1, 0.5));
        if (d > 0.15) continue;
        color += vec3(sin(fi), cos(fi * 2.0), 0.5) * smoothstep(0.15, 0.0, d);
    }
    fragColor = vec4(color, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 color = vec3(0.0);

    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float d = distance(uv, vec2(0.5 + fi * 0.1, 0.5));
        if (d < 0.05) {
            if (uv.x > 0.5) {
                color += vec3(1.0, 0.5, 0.2) * (1.0 - d / 0.05);
            } else {
                discard;
            }
        }
    }

    if (uv.y < 0.1 || uv.y > 0.9) {
        discard;
    }

    fragColor = vec4(color, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Nested conditional with early returns
    vec3 col;

    if (uv.x < 0.25) {
        col = vec3(0.8, 0.2, 0.1);
        if (uv.y < 0.5) {
            col *= 0.5;
        }
    } else if (uv.x < 0.5) {
        col = vec3(0.1, 0.8, 0.2);
        col *= 0.5 + 0.5 * sin(uv.y * 6.28);
    } else if (uv.x < 0.75) {
        col = vec3(0.1, 0.2, 0.8);
        col *= smoothstep(0.0, 1.0, uv.y);
    } else {
        col = vec3(0.9, 0.9, 0.1);
        col *= uv.y;
    }

    fragColor = vec4(col, 1.0);
}

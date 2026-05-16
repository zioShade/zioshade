#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Gradient with smooth color stops
    float t = uv.x;

    vec3 c1 = vec3(0.1, 0.0, 0.3);
    vec3 c2 = vec3(0.7, 0.1, 0.4);
    vec3 c3 = vec3(1.0, 0.7, 0.2);
    vec3 c4 = vec3(0.1, 0.8, 0.6);

    vec3 col;
    if (t < 0.33) {
        col = mix(c1, c2, t / 0.33);
    } else if (t < 0.66) {
        col = mix(c2, c3, (t - 0.33) / 0.33);
    } else {
        col = mix(c3, c4, (t - 0.66) / 0.34);
    }

    col *= 0.8 + 0.2 * sin(uv.y * 6.28);
    fragColor = vec4(col, 1.0);
}

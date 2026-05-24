#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    float t = uv.x;
    vec3 a = vec3(1.0, 0.3, 0.1);
    vec3 b = vec3(0.1, 0.5, 1.0);
    vec3 c = vec3(0.9, 0.2, 0.8);

    // Bezier curve color gradient
    float one_minus_t = 1.0 - t;
    vec3 color = one_minus_t * one_minus_t * a + 2.0 * one_minus_t * t * b + t * t * c;

    // Vertical fade
    float fade = smoothstep(0.0, 0.5, uv.y) * smoothstep(1.0, 0.5, uv.y);
    color *= fade;

    fragColor = vec4(color, 1.0);
}

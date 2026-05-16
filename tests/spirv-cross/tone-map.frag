#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Gamma correction and tone mapping
    vec3 linear = vec3(uv.x, uv.y, uv.x * uv.y);

    // Reinhard tone mapping
    vec3 mapped = linear / (linear + vec3(1.0));

    // Gamma correction
    vec3 gamma = pow(mapped, vec3(1.0 / 2.2));

    fragColor = vec4(gamma, 1.0);
}

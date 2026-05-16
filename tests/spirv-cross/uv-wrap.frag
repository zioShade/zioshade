#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Texture coordinate wrapping modes
    vec2 repeat_uv = fract(uv * 3.0);
    vec2 mirrored_uv = 1.0 - abs(fract(uv * 2.0) * 2.0 - 1.0);
    vec2 clamp_uv = clamp(uv, 0.0, 1.0);

    float r = repeat_uv.x;
    float g = mirrored_uv.y;
    float b = clamp_uv.x * clamp_uv.y;

    fragColor = vec4(r, g, b, 1.0);
}

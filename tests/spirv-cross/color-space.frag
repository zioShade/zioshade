#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Color space conversions
    // Linear to sRGB
    vec3 linear = vec3(uv.x, uv.y, uv.x * uv.y);
    vec3 srgb = pow(linear, vec3(1.0 / 2.2));

    // sRGB to linear
    vec3 back_linear = pow(srgb, vec3(2.2));

    // Luminance
    float lum = dot(back_linear, vec3(0.2126, 0.7152, 0.0722));

    fragColor = vec4(vec3(lum), 1.0);
}

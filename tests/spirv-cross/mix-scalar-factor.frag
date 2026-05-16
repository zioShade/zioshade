#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Mix with scalar factor (component-wise promotion)
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 c = mix(a, b, uv.x);
    vec3 d = clamp(c * 2.0 - 0.5, 0.0, 1.0);

    fragColor = vec4(d, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

vec3 palette(float t) {
    vec3 a = vec3(0.5, 0.5, 0.5);
    vec3 b = vec3(0.5, 0.5, 0.5);
    vec3 c = vec3(1.0, 1.0, 1.0);
    vec3 d = vec3(0.263, 0.416, 0.557);
    return a + b * cos(6.28318 * (c * t + d));
}

void main()
{
    // Classic Shadertoy-style palette function
    vec3 col = palette(length(uv));
    fragColor = vec4(col, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main()
{
    // HSV to RGB conversion (classic shader utility)
    float hue = uv.x;
    float sat = 0.8;
    float val = 0.5 + 0.5 * sin(uv.y * 6.28);
    vec3 col = hsv2rgb(vec3(hue, sat, val));
    fragColor = vec4(col, 1.0);
}

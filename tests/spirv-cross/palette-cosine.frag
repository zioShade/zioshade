#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// IQ's palette function
vec3 palette(float t) {
    vec3 a = vec3(0.5, 0.5, 0.5);
    vec3 b = vec3(0.5, 0.5, 0.5);
    vec3 c = vec3(1.0, 1.0, 1.0);
    vec3 d = vec3(0.263, 0.416, 0.557);
    return a + b * cos(6.28318 * (c * t + d));
}

void main() {
    vec2 p = uv * 2.0 - 1.0;
    float d = length(p);
    float angle = atan(p.y, p.x);

    float color1 = sin(d * 8.0 - angle * 3.0) * 0.5 + 0.5;
    float color2 = cos(d * 6.0 + angle * 2.0) * 0.5 + 0.5;

    vec3 col = palette(color1 + color2);
    col *= 1.0 - d * 0.5;

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Lissajous curve
    float t = uv.x * 6.28318 * 3.0;
    vec2 p = uv * 2.0 - 1.0;

    float a = 3.0;
    float b = 2.0;
    float x = sin(a * t) * 0.7;
    float y = sin(b * t + 1.57) * 0.7;

    float dist = length(p - vec2(x, y));
    float col = smoothstep(0.05, 0.0, dist);

    vec3 color = vec3(col * 0.8, col * 0.3, col * 1.0);
    color += vec3(0.02, 0.02, 0.05);

    fragColor = vec4(color, 1.0);
}

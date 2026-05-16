#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Plasma effect using sin combinations
    float v1 = sin(uv.x * 10.0);
    float v2 = sin(uv.y * 10.0);
    float v3 = sin((uv.x + uv.y) * 10.0);
    float v4 = sin(length(uv - 0.5) * 14.0);

    float val = (v1 + v2 + v3 + v4) * 0.25;

    vec3 col;
    col.r = sin(val * 3.14159 + 0.0) * 0.5 + 0.5;
    col.g = sin(val * 3.14159 + 2.094) * 0.5 + 0.5;
    col.b = sin(val * 3.14159 + 4.189) * 0.5 + 0.5;

    fragColor = vec4(col, 1.0);
}

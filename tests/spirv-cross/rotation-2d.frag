#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // 2D rotation matrix
    float angle = uv.x * 6.28318;
    float c = cos(angle);
    float s = sin(angle);

    vec2 p = uv * 2.0 - 1.0;
    vec2 rotated = vec2(
        c * p.x - s * p.y,
        s * p.x + c * p.y
    );

    float d = length(rotated);
    float ring = abs(d - 0.5);
    float col = smoothstep(0.05, 0.0, ring);

    fragColor = vec4(col * rotated.x * 0.5 + 0.5, col * rotated.y * 0.5 + 0.5, col, 1.0);
}

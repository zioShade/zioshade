#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    int ix = int(uv.x * 10.0);
    int iy = int(uv.y * 10.0);

    int abs_val = abs(ix - 5);
    int sign_val = sign(ix - 5);
    int clamped = clamp(iy, 2, 8);
    int min_val = min(ix, iy);
    int max_val = max(ix, iy);

    float r = float(abs_val) / 10.0;
    float g = float(clamped) / 10.0;
    float b = float(min_val + max_val) / 20.0;
    float a = float(sign_val + 1) * 0.5;
    fragColor = vec4(r, g, b, a);
}

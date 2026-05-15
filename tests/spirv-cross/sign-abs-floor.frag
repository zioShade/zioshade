#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test sign, abs, ceil, floor combinations
    float x = uv.x * 4.0 - 2.0;
    float y = uv.y * 4.0 - 2.0;
    float sx = sign(x);
    float sy = sign(y);
    float ax = abs(x);
    float ay = abs(y);
    float cx = ceil(ax);
    float fy = floor(ay);
    fragColor = vec4(sx * 0.5 + 0.5, sy * 0.5 + 0.5, cx / 3.0, fy / 3.0);
}

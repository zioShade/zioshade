#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test nested for loops
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            sum += float(i * 4 + j) / 16.0;
        }
    }
    float scale = sum / 4.0;
    fragColor = vec4(uv.x * scale, uv.y * scale, scale, 1.0);
}

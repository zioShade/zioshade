#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test various loop patterns
    float sum = 0.0;
    for (int i = 0; i < 10; i++) {
        sum += float(i) * 0.1;
    }
    int j = 0;
    while (j < 5) {
        sum += float(j) * 0.05;
        j++;
    }
    float result = sum * uv.x + uv.y * 0.5;
    fragColor = vec4(result, result * 0.8, result * 0.6, 1.0);
}

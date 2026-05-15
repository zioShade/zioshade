#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test nested loops with break and continue
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            if (i == j) continue;
            if (i + j > 5) break;
            sum += float(i * 4 + j) * u;
        }
    }
    fragColor = vec4(sum, sum, sum, 1.0);
}

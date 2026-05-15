#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test constant array and indexing
    const float weights[5] = float[5](0.1, 0.2, 0.4, 0.2, 0.1);
    int idx = int(uv.x * 4.0);
    idx = clamp(idx, 0, 4);
    float w = weights[idx];
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        sum += weights[i];
    }
    fragColor = vec4(w, sum, uv.y, 1.0);
}

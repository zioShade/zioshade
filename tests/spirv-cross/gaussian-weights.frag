#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Approximate Gaussian blur weights
    float w0 = 0.227027;
    float w1 = 0.1945946;
    float w2 = 0.1216216;
    float w3 = 0.054054;
    float total = w0 + 2.0 * (w1 + w2 + w3);
    float normalized_w0 = w0 / total;
    float normalized_w1 = w1 / total;

    float result = normalized_w0 * uv.x + normalized_w1 * uv.y;
    fragColor = vec4(vec3(result), 1.0);
}

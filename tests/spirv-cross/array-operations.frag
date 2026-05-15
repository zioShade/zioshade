#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test array operations
    float arr[4];
    arr[0] = 1.0;
    arr[1] = 2.0;
    arr[2] = 3.0;
    arr[3] = 4.0;
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        sum += arr[i] * uv.x;
    }
    fragColor = vec4(sum / 10.0);
}

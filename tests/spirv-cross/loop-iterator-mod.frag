#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Loop with iterator modification
    float sum = 0.0;
    for (int i = 0; i < 10; i += 2) {
        float val = uv.x * float(i);
        sum += val;
        if (sum > 3.0) {
            i += 1;  // skip ahead
        }
    }
    fragColor = vec4(sum * 0.1, uv.x, uv.y, 1.0);
}

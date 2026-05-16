#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Loop with accumulator pattern and multiple break conditions
    float acc = 0.0;
    for (int i = 0; i < 20; i++) {
        float fi = float(i);
        float val = sin(uv.x * fi) * cos(uv.y * fi);
        if (val > 0.9) break;
        if (val < -0.9) continue;
        acc += val;
        if (acc > 5.0) break;
    }
    fragColor = vec4(acc * 0.1, sin(uv.x), cos(uv.y), 1.0);
}

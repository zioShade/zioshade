#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Multiple nested loops with breaks and continues
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            float val = uv.x * float(i) + uv.y * float(j);
            if (val > 2.0) break;
            if (val < 0.5) continue;
            sum += val;
        }
    }
    fragColor = vec4(sum * 0.1, uv.x, uv.y, 1.0);
}

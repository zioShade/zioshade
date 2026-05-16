#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Do-while loop with return and explicit component construction
    int count = 0;
    do {
        float val = uv.x + float(count) * 0.1;
        if (val > 0.8) {
            fragColor = vec4(val, uv.y, 0.0, 1.0);
            return;
        }
        count++;
    } while (count < 10);

    fragColor = vec4(0.0, uv.x, uv.y, 1.0);
}

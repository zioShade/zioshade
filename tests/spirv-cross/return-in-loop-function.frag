#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

float search(float target, vec2 pos) {
    for (int i = 0; i < 8; i++) {
        float val = pos.x * float(i) + pos.y;
        if (val > target) {
            return val;
        }
    }
    return target;
}

void main()
{
    // Function with return-in-loop, called from main
    float a = search(2.0, uv);
    float b = search(1.5, vec2(uv.y, uv.x));

    // Main also has return-in-loop
    for (int i = 0; i < 3; i++) {
        if (uv.x * float(i) > 1.5) {
            fragColor = vec4(a, b, 0.0, 1.0);
            return;
        }
    }
    fragColor = vec4(a * 0.5, b * 0.5, uv.x, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

float getValue(float x) {
    return x * 2.0;
}

void main()
{
    // More complex: multiple loads after return-in-loop
    vec2 result = vec2(0.0);
    for (int i = 0; i < 10; i++) {
        float val = getValue(uv.x);
        if (val > 1.5) {
            fragColor = vec4(val, 0.0, 0.0, 1.0);
            return;
        }
        result.x += val * 0.1;
    }
    // Uses uv after loop — must not reuse loop body load
    fragColor = vec4(result.x, uv.y, uv.x * 0.5, 1.0);
}

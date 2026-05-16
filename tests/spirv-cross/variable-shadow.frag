#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Variable shadowing across nested scopes
    float val = uv.x;

    if (uv.y > 0.5) {
        float val = uv.x * 2.0;
        if (val > 1.0) {
            float val = 0.5;
            fragColor = vec4(val, 0.0, 0.0, 1.0);
            return;
        }
        fragColor = vec4(val, 0.5, 0.0, 1.0);
        return;
    }

    fragColor = vec4(val, val, val, 1.0);
}

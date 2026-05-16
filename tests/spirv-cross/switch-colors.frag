#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Switch with fall-through and break
    int mode = int(uv.x * 4.0);
    float r = 0.0;
    float g = 0.0;
    switch (mode) {
        case 0:
            r = 1.0;
            g = 0.0;
            break;
        case 1:
            r = 0.0;
            g = 1.0;
            break;
        case 2:
            r = 0.5;
            g = uv.y;
            break;
        default:
            r = uv.x;
            g = uv.y;
            break;
    }
    fragColor = vec4(r, g, 0.5, 1.0);
}

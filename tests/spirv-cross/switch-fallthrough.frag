#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test switch statement
    int i = int(u * 4.0) % 4;
    float result = 0.0;
    switch (i) {
        case 0: result = 1.0; break;
        case 1: result = 2.0; break;
        case 2: result = 3.0; break;
        case 3: result = 4.0; break;
        default: result = -1.0; break;
    }
    fragColor = vec4(result, float(i), u, 1.0);
}

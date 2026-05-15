#version 450

layout(binding = 0) uniform sampler2D tex;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // 3x3 kernel blur
    vec4 sum = vec4(0.0);
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 offset = vec2(float(x), float(y)) * 0.01;
            sum += texture(tex, uv + offset);
        }
    }
    fragColor = sum / 9.0;
}

#version 450

layout(binding = 0) uniform sampler2D tex;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    vec4 a = texture(tex, uv);
    vec4 b = texture(tex, uv + vec2(0.01, 0.0));
    vec4 c = texture(tex, uv + vec2(0.0, 0.01));
    vec4 d = texture(tex, uv + vec2(0.01, 0.01));
    fragColor = (a + b + c + d) * 0.25;
}

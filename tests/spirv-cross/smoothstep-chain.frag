#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test smoothstep and mix chains
    float edge0 = 0.2;
    float edge1 = 0.8;
    float s = smoothstep(edge0, edge1, uv.x);
    float m = mix(0.0, 1.0, s);
    float c = clamp(uv.y * m, 0.0, 1.0);
    float st = step(0.5, c);
    fragColor = vec4(st, m, c, 1.0);
}

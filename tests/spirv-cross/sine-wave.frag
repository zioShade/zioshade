#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Sine wave pattern
    float wave = sin(uv.x * 20.0 + uv.y * 5.0) * 0.5 + 0.5;
    float wave2 = cos(uv.y * 15.0 - uv.x * 3.0) * 0.5 + 0.5;
    float blend = mix(wave, wave2, 0.5);
    fragColor = vec4(blend, blend * 0.7, 1.0 - blend, 1.0);
}

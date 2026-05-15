#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Sine wave pattern
    float wave = sin(uv.x * 20.0) * 0.5 + 0.5;
    float mask = step(0.3, wave) * step(wave, 0.7);
    vec3 color = mix(vec3(0.0, 0.0, 0.5), vec3(0.0, 0.5, 1.0), mask);
    fragColor = vec4(color, 1.0);
}

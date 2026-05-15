#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Radial gradient with smoothstep
    float d = length(uv - vec2(0.5));
    float inner = smoothstep(0.0, 0.3, d);
    float outer = smoothstep(0.3, 0.5, d);
    vec3 color = mix(vec3(1.0, 0.8, 0.2), vec3(0.2, 0.4, 0.8), outer);
    fragColor = vec4(color * inner, 1.0);
}

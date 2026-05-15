#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Fresnel-like edge glow
    float d = length(uv - vec2(0.5));
    float fresnel = pow(1.0 - max(1.0 - d * 2.0, 0.0), 3.0);
    vec3 inner = vec3(0.1, 0.2, 0.4);
    vec3 outer = vec3(0.5, 0.8, 1.0);
    vec3 color = mix(inner, outer, fresnel);
    fragColor = vec4(color, 1.0);
}

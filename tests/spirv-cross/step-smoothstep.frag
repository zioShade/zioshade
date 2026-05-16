#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Step and smoothstep edge cases
    float edge1 = 0.3;
    float edge2 = 0.7;
    float s = step(edge1, uv.x);
    float ss = smoothstep(edge1, edge2, uv.y);

    vec3 color = vec3(s, ss, s * ss);
    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}

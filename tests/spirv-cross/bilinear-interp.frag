#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test smooth interpolation across a surface
    float t = smoothstep(0.0, 1.0, uv.x);
    float s = smoothstep(0.0, 1.0, uv.y);
    vec3 c1 = vec3(1.0, 0.0, 0.0);
    vec3 c2 = vec3(0.0, 1.0, 0.0);
    vec3 c3 = vec3(0.0, 0.0, 1.0);
    vec3 c4 = vec3(1.0, 1.0, 0.0);
    vec3 top = mix(c1, c2, t);
    vec3 bot = mix(c3, c4, t);
    vec3 result = mix(bot, top, s);
    fragColor = vec4(result, 1.0);
}

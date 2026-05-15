#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Fire-like effect using sin/cos stacking
    float t = uv.y * 10.0;
    float wave1 = sin(uv.x * 10.0 + t) * 0.5 + 0.5;
    float wave2 = sin(uv.x * 15.0 - t * 1.5) * 0.5 + 0.5;
    float wave3 = sin(uv.x * 20.0 + t * 0.7) * 0.5 + 0.5;
    float fire = (wave1 + wave2 + wave3) / 3.0;
    fire *= 1.0 - uv.y;
    vec3 color = mix(vec3(0.1, 0.0, 0.0), vec3(1.0, 0.5, 0.0), fire);
    color = mix(color, vec3(1.0, 1.0, 0.5), fire * fire);
    fragColor = vec4(color, 1.0);
}

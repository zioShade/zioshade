#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Simple gradient with multiple stops
    float t = uv.x;
    vec3 color;
    if (t < 0.25) {
        color = mix(vec3(1.0, 0.0, 0.0), vec3(1.0, 1.0, 0.0), t * 4.0);
    } else if (t < 0.5) {
        color = mix(vec3(1.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0), (t - 0.25) * 4.0);
    } else if (t < 0.75) {
        color = mix(vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0), (t - 0.5) * 4.0);
    } else {
        color = mix(vec3(0.0, 0.0, 1.0), vec3(1.0, 0.0, 1.0), (t - 0.75) * 4.0);
    }
    fragColor = vec4(color, 1.0);
}

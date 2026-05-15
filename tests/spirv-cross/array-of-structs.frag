#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test array of structs
    struct Light {
        vec3 color;
        float intensity;
    };
    Light lights[3];
    lights[0] = Light(vec3(1.0, 0.0, 0.0), 0.5);
    lights[1] = Light(vec3(0.0, 1.0, 0.0), 0.8);
    lights[2] = Light(vec3(0.0, 0.0, 1.0), 1.0);
    int idx = int(uv.x * 2.0);
    idx = clamp(idx, 0, 2);
    vec3 c = lights[idx].color * lights[idx].intensity;
    fragColor = vec4(c * uv.y, 1.0);
}

#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

float compute(float x) {
    return x * x + sin(x) * cos(x);
}

vec3 process(vec3 v) {
    return vec3(compute(v.x), compute(v.y), compute(v.z));
}

void main()
{
    float val = u * 3.14;
    vec3 input_vec = vec3(val, val * 0.5, val * 0.25);
    vec3 result = process(input_vec);
    fragColor = vec4(result, 1.0);
}

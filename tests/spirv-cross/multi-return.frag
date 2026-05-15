#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multi-return function
float computeWeight(vec2 p) {
    float d = length(p);
    if (d < 0.1) return 1.0;
    if (d < 0.3) return 0.8;
    if (d < 0.5) return 0.5;
    return 0.0;
}

void main()
{
    float w = computeWeight(uv - vec2(0.5));
    vec3 color = vec3(w, w * 0.7, w * 0.3);
    fragColor = vec4(color, 1.0);
}

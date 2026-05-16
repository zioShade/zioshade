#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

float scale(vec2 p, float s) {
    return length(p) * s;
}

float pattern(vec2 p, float t) {
    return sin(scale(p, t)) * cos(p.x * 3.0);
}

float effect(vec2 p) {
    return pattern(p + uv, 2.0) + scale(p, 0.5);
}

void main()
{
    // Triple nested function calls with uniforms
    float r = effect(vec2(0.5));
    fragColor = vec4(r, abs(r), r * 0.5, 1.0);
}

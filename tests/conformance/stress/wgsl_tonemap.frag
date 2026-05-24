#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

float saturate(float x) {
    return clamp(x, 0.0, 1.0);
}

vec3 tonemap(vec3 c) {
    return c / (c + vec3(1.0));
}

void main() {
    vec3 color = vec3(uv.x, uv.y, 0.5);
    color = tonemap(color);
    float lum = dot(color, vec3(0.299, 0.587, 0.114));
    float s = saturate(lum);
    color *= s;
    fragColor = vec4(color, 1.0);
}

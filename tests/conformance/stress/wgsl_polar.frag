#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float theta = atan(p.y, p.x);

    vec3 color = vec3(0.0);
    color.r = smoothstep(0.0, 1.0, sin(theta * 3.0) * 0.5 + 0.5);
    color.g = smoothstep(0.0, 1.0, cos(theta * 5.0) * 0.5 + 0.5);
    color.b = smoothstep(0.3, 0.7, r);

    float ring = abs(fract(r * 5.0) - 0.5) * 2.0;
    color *= smoothstep(0.0, 0.1, ring);

    fragColor = vec4(color, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Fibonacci spiral pattern
    float golden = 1.618033988749;
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float angle = atan(p.y, p.x);

    // Golden angle spiral
    float n = angle / 2.35619 + r * 5.0;
    float spiral = fract(n * golden);

    float mask = smoothstep(0.8, 0.0, r);
    vec3 col = vec3(spiral, spiral * 0.7, 0.3 + spiral * 0.4) * mask;

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

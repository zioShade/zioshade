#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Kaleidoscope pattern
    vec2 p = uv * 2.0 - 1.0;
    float angle = atan(p.y, p.x);
    float r = length(p);

    // Fold into 8 segments
    float segments = 8.0;
    float seg_angle = 6.28318 / segments;
    angle = mod(angle, seg_angle);
    angle = abs(angle - seg_angle * 0.5);

    vec2 q = vec2(cos(angle), sin(angle)) * r;

    // Pattern within segment
    float pattern = sin(q.x * 10.0) * cos(q.y * 10.0);
    pattern = pattern * 0.5 + 0.5;

    vec3 col = mix(vec3(0.1, 0.0, 0.2), vec3(0.9, 0.5, 0.1), pattern);
    col *= smoothstep(1.0, 0.2, r);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

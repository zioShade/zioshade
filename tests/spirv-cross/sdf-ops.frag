#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // SDF operations: union, smooth union, intersection
    vec2 p = uv * 4.0 - 2.0;

    float d1 = length(p - vec2(-0.5, 0.0)) - 0.8;
    float d2 = length(p - vec2(0.5, 0.0)) - 0.8;
    float d3 = length(p - vec2(0.0, 0.7)) - 0.6;

    // Union
    float u = min(d1, min(d2, d3));

    // Smooth union
    float k = 0.5;
    float su1 = min(d1, d2);
    float h1 = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    su1 = mix(d2, d1, h1) - k * h1 * (1.0 - h1);

    // Color based on closest shape
    float closest = 0.0;
    if (d1 < d2 && d1 < d3) closest = 1.0;
    else if (d2 < d3) closest = 2.0;

    vec3 col = vec3(0.0);
    col += smoothstep(0.02, 0.0, u) * vec3(0.5 + closest * 0.2);
    col += vec3(0.1) * smoothstep(0.02, 0.05, abs(u));

    fragColor = vec4(col, 1.0);
}

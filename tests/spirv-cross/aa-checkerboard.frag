#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Anti-aliased checkerboard with perspective
    float scale = 20.0;
    vec2 p = uv * scale;

    // Perspective warp
    p *= 1.0 + uv.y;

    // Anti-aliasing using fwidth-like approach
    vec2 fw = vec2(abs(dFdx(p.x)) + abs(dFdx(p.y)),
                   abs(dFdy(p.x)) + abs(dFdy(p.y)));
    vec2 edge = smoothstep(vec2(0.0), fw * 1.5, abs(fract(p - 0.5) - 0.5));
    float checker = mix(mod(floor(p.x) + floor(p.y), 2.0), 0.5, (edge.x + edge.y) * 0.5);

    vec3 col = vec3(checker) * vec3(0.9, 0.85, 0.8);

    fragColor = vec4(col, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Convex polygon SDF (hexagon)
    vec2 p = uv * 2.0 - 1.0;
    float r = 0.5;
    float n = 6.0;
    float an = 3.14159265 / n;
    float he = r * cos(an) / cos(mod(atan(p.y, p.x), 2.0 * an) - an);
    float d = length(p) - he;

    float fill = 1.0 - smoothstep(0.0, 0.02, d);

    vec3 col = vec3(0.3, 0.5, 0.8) * fill;
    col += vec3(0.1) * (1.0 - fill);

    fragColor = vec4(col, 1.0);
}

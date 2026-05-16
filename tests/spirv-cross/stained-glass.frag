#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Stained glass effect
    vec2 p = uv * 4.0;
    vec2 ip = floor(p);
    vec2 fp = fract(p);

    // Lead lines (dark borders)
    float border = min(min(fp.x, 1.0 - fp.x), min(fp.y, 1.0 - fp.y));
    float lead = 1.0 - smoothstep(0.03, 0.06, border);

    // Cell color from hash
    float h = fract(sin(dot(ip, vec2(127.1, 311.7))) * 43758.5453);
    vec3 col = vec3(
        0.3 + 0.7 * sin(h * 6.28 + 0.0),
        0.3 + 0.7 * sin(h * 6.28 + 2.094),
        0.3 + 0.7 * sin(h * 6.28 + 4.189)
    );

    col *= 0.6 + 0.4 * length(fp - 0.5);

    // Lead is dark
    col = mix(col, vec3(0.05), lead);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

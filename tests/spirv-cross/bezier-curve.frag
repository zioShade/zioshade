#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Bezier curve evaluation
    vec2 p0 = vec2(0.1, 0.2);
    vec2 p1 = vec2(0.5, 0.9);
    vec2 p2 = vec2(0.9, 0.1);

    float min_dist = 1.0;
    for (int i = 0; i <= 32; i++) {
        float t = float(i) / 32.0;
        vec2 pos = (1.0 - t) * (1.0 - t) * p0 + 2.0 * (1.0 - t) * t * p1 + t * t * p2;
        float d = length(uv - pos);
        min_dist = min(min_dist, d);
    }

    float col = smoothstep(0.02, 0.0, min_dist);
    vec3 curve_col = vec3(0.3, 0.6, 1.0) * col;
    curve_col += vec3(0.05, 0.05, 0.08) * (1.0 - col);

    fragColor = vec4(curve_col, 1.0);
}

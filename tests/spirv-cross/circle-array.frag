#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Depth of field blur simulation
    vec2 p = uv * 2.0 - 1.0;

    // Multiple concentric dots
    float col = 0.0;
    for (int i = 0; i < 12; i++) {
        float angle = float(i) * 0.5236;  // 2*PI/12
        vec2 center = vec2(cos(angle), sin(angle)) * 0.5;
        float d = length(p - center);
        col += smoothstep(0.1, 0.05, d);
    }

    col = min(col, 1.0);
    vec3 color = vec3(col * 0.3, col * 0.7, col);

    fragColor = vec4(color, 1.0);
}

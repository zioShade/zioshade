#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Nested loop: multiplication table visualization
    float col = 0.0;
    for (int i = 1; i <= 4; i++) {
        for (int j = 1; j <= 4; j++) {
            vec2 center = vec2(float(i) * 0.2, float(j) * 0.2);
            float d = length(uv - center);
            float brightness = float(i * j) / 16.0;
            col += smoothstep(0.05, 0.0, d) * brightness;
        }
    }
    col = min(col, 1.0);

    fragColor = vec4(col, col * 0.8, col * 0.6, 1.0);
}

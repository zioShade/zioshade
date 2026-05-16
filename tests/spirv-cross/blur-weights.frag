#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Approximate Gaussian blur weights
    float w[5];
    w[0] = 0.05448868;
    w[1] = 0.24420134;
    w[2] = 0.40261995;
    w[3] = 0.24420134;
    w[4] = 0.05448868;

    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        float offset = float(i - 2) * 0.05;
        sum += w[i] * sin((uv.x + offset) * 10.0);
    }

    vec3 col = vec3(sum * 0.5 + 0.5);
    col *= vec3(0.8, 0.9, 1.0);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

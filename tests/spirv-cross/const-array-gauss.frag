#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test uniform-like constant arrays
const float gauss[5] = float[5](0.0545, 0.2442, 0.4026, 0.2442, 0.0545);

void main() {
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        float offset = (float(i) - 2.0) * 0.05;
        sum += gauss[i] * sin((uv.x + offset) * 10.0);
    }
    
    vec3 col = vec3(sum * 0.5 + 0.5);
    col *= vec3(0.8, 0.9, 1.0);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

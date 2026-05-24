#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test classic for loop with iterator
void main() {
    float sum = 0.0;
    for (int i = 0; i < 10; i++) {
        sum += sin(float(i) * uv.x) * 0.1;
    }
    vec3 color = vec3(sum, sum * uv.y, sum * 0.5);
    fragColor = vec4(color, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple early returns
float classify(float x) {
    if (x < 0.25) return 0.0;
    if (x < 0.5) return 1.0;
    if (x < 0.75) return 2.0;
    return 3.0;
}

void main() {
    float c = classify(uv.x);
    vec3 color = vec3(c * 0.33);
    fragColor = vec4(color, 1.0);
}

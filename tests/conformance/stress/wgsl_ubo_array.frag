// Tests: uniform buffer array access
#version 450
layout(std140, binding = 0) uniform Data {
    vec4 colors[4];
    float scale;
};

layout(location = 0) out vec4 fragColor;

void main() {
    int idx = 2;
    vec4 c = colors[idx] * scale;
    fragColor = c;
}

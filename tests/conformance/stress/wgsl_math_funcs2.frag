#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test power, exp2, log2, sqrt
void main() {
    float a = pow(uv.x, 2.0);
    float b = exp2(uv.y * 3.0);
    float c = log2(uv.x + 1.0);
    float d = sqrt(uv.y);
    float e = inversesqrt(uv.x + 0.01);
    vec3 color = vec3(a * 0.2, b * 0.1, c * d * e);
    fragColor = vec4(color, 1.0);
}

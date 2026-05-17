#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test complex initializer expressions
void main() {
    float a = sin(uv.x * 3.14) * 0.5 + 0.5;
    float b = cos(uv.y * 6.28) * a;
    float c = sqrt(clamp(a * a + b * b, 0.0, 1.0));
    
    // Use initialized values in further expressions
    float d = mix(a, b, c);
    float e = fract(d * 5.0 + a);
    
    vec3 col = vec3(d, e, c);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test complex expression trees
void main() {
    float a = sin(uv.x * 10.0 + cos(uv.y * 5.0)) * 0.5 + 0.5;
    float b = cos(uv.y * 8.0 + sin(uv.x * 3.0)) * 0.5 + 0.5;
    float c = sin(a * 6.28 + b * 3.14) * cos(b * 6.28 - a * 1.57);
    
    // Nested function calls in expressions
    float d = pow(abs(c), 0.5) * mix(a, b, 0.5);
    float e = smoothstep(0.2, 0.8, d) * clamp(c + 0.5, 0.0, 1.0);
    
    vec3 col = vec3(a * e, b * e, e);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

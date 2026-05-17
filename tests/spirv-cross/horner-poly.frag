#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Polynomial evaluation with Horner's method
float poly(float x) {
    // 3x^4 - 2x^3 + x^2 - 5x + 1
    return ((((3.0 * x - 2.0) * x + 1.0) * x - 5.0) * x + 1.0);
}

void main() {
    float x = uv.x * 4.0 - 2.0;
    float y = poly(x);
    float y2 = poly(uv.y * 2.0);
    
    vec3 col = vec3(
        clamp(y * 0.2 + 0.5, 0.0, 1.0),
        clamp(y2 * 0.3 + 0.5, 0.0, 1.0),
        clamp((y + y2) * 0.1 + 0.5, 0.0, 1.0)
    );
    
    fragColor = vec4(col, 1.0);
}

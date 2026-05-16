#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test compound assignment operators: +=, -=, *=, /=
void main() {
    float a = uv.x;
    float b = uv.y;
    
    a += 0.1;       // a = a + 0.1
    b -= 0.05;      // b = b - 0.05
    a *= 2.0;       // a = a * 2.0
    b /= 1.5;       // b = b / 1.5
    
    // Compound with expressions
    a += b * 0.3;
    b -= a * 0.1;
    
    vec3 col = vec3(clamp(a, 0.0, 1.0), clamp(b, 0.0, 1.0), 0.5);
    fragColor = vec4(col, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test compound assignment operators
void main() {
    float a = uv.x;
    float b = uv.y;
    
    a += 0.1;
    b -= 0.2;
    a *= 2.0;
    b /= 3.0;
    
    float c = a;
    c += b;
    c *= a;
    c -= b;
    c /= (a + 0.01);
    
    vec3 col = vec3(a, b, c);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

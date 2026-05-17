#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test transpose and matrix multiply
void main() {
    mat2 m = mat2(uv.x, uv.y, -uv.y, uv.x);
    mat2 t = transpose(m);
    
    // m * transpose(m) should give scalar * identity
    mat2 product = m * t;
    
    float det = uv.x * uv.x + uv.y * uv.y;
    
    float a = product[0][0] / (det + 0.01);
    float b = product[0][1];
    
    vec3 col = vec3(a, abs(b), det * 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

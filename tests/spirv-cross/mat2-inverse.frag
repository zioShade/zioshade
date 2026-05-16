#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test determinant and inverse of mat2
void main() {
    float a = uv.x * 2.0;
    float b = uv.y;
    float c = -uv.y;
    float d = uv.x + 0.5;
    
    mat2 m = mat2(a, b, c, d);
    float det = a * d - b * c;
    
    // Manual inverse of 2x2
    float inv_det = 1.0 / (det + 0.001);
    mat2 inv_m = inv_det * mat2(d, -b, -c, a);
    
    // Should give identity (approximately)
    mat2 product = m * inv_m;
    float identity_check = abs(product[0][0] - 1.0) + abs(product[0][1]) + abs(product[1][0]) + abs(product[1][1] - 1.0);
    
    float col = clamp(1.0 - identity_check * 10.0, 0.0, 1.0);
    fragColor = vec4(col, col * det, col * a, 1.0);
}

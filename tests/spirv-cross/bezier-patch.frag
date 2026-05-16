#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Cubic Bezier patch evaluation
void main() {
    float u = uv.x;
    float v = uv.y;
    
    // Bezier basis functions
    float bu0 = (1.0 - u) * (1.0 - u) * (1.0 - u);
    float bu1 = 3.0 * u * (1.0 - u) * (1.0 - u);
    float bu2 = 3.0 * u * u * (1.0 - u);
    float bu3 = u * u * u;
    
    float bv0 = (1.0 - v) * (1.0 - v) * (1.0 - v);
    float bv1 = 3.0 * v * (1.0 - v) * (1.0 - v);
    float bv2 = 3.0 * v * v * (1.0 - v);
    float bv3 = v * v * v;
    
    // 4x4 control points (z values only)
    float P00 = 0.0, P01 = 0.2, P02 = 0.3, P03 = 0.1;
    float P10 = 0.1, P11 = 0.8, P12 = 0.7, P13 = 0.2;
    float P20 = 0.2, P21 = 0.7, P22 = 0.9, P23 = 0.3;
    float P30 = 0.1, P31 = 0.3, P32 = 0.4, P33 = 0.2;
    
    float height = 
        bu0 * (bv0 * P00 + bv1 * P01 + bv2 * P02 + bv3 * P03) +
        bu1 * (bv0 * P10 + bv1 * P11 + bv2 * P12 + bv3 * P13) +
        bu2 * (bv0 * P20 + bv1 * P21 + bv2 * P22 + bv3 * P23) +
        bu3 * (bv0 * P30 + bv1 * P31 + bv2 * P32 + bv3 * P33);
    
    vec3 col = vec3(height);
    col *= vec3(0.3, 0.6, 0.9);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test isnan, isinf
void main() {
    float a = uv.x / (uv.y - 0.5);  // can overflow
    
    float nan_check = isnan(a) ? 1.0 : 0.0;
    float inf_check = isinf(a) ? 1.0 : 0.0;
    float finite_check = (isinf(a) || isnan(a)) ? 0.0 : 1.0;
    
    float r = finite_check * uv.x;
    float g = nan_check;
    float b = inf_check;
    
    fragColor = vec4(r, g, b, 1.0);
}

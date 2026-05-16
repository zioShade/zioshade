#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test exp, log, pow chain
void main() {
    float x = uv.x * 4.0;
    float y = uv.y;
    
    // e^x -> ln -> pow cycle
    float ex = exp(x);
    float ln_ex = log(ex);
    float pow_val = pow(ln_ex, y * 2.0);
    
    float r = clamp(ex / 50.0, 0.0, 1.0);
    float g = clamp(ln_ex / 4.0, 0.0, 1.0);
    float b = clamp(pow_val / 10.0, 0.0, 1.0);
    
    fragColor = vec4(r, g, b, 1.0);
}

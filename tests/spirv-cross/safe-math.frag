#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test clamping patterns for safe math
void main() {
    float x = uv.x * 2.0 - 1.0;
    float y = uv.y * 2.0 - 1.0;
    
    // Safe sqrt
    float sq = sqrt(max(x, 0.0));
    
    // Safe division
    float div = x / (y * y + 0.01);
    
    // Safe log
    float log_val = log(max(abs(x), 0.001));
    
    // Safe pow
    float pow_val = pow(max(abs(x), 0.001), max(y * 3.0, 0.1));
    
    vec3 col = vec3(sq, clamp(div * 0.5 + 0.5, 0.0, 1.0), clamp(log_val * 0.3 + 0.5, 0.0, 1.0));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

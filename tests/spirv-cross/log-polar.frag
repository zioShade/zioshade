#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test UV manipulation with polar coordinates
void main() {
    vec2 centered = uv * 2.0 - 1.0;
    float r = length(centered);
    float a = atan(centered.y, centered.x);
    
    // Log-polar remapping
    float log_r = log(r + 0.01) * 2.0;
    float norm_a = a / 6.28318 + 0.5;
    
    // Sample pattern in log-polar space
    float pattern = sin(log_r * 10.0) * cos(norm_a * 20.0);
    pattern = pattern * 0.5 + 0.5;
    
    vec3 col = vec3(pattern, log_r * 0.3 + 0.5, norm_a);
    col *= smoothstep(1.5, 0.1, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

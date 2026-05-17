#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mat2 * vec2 pattern for 2D transforms
void main() {
    float angle = uv.x * 6.28;
    mat2 rot = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
    
    vec2 p = uv * 2.0 - 1.0;
    vec2 transformed = rot * p;
    
    // Check inverse rotation
    mat2 inv_rot = mat2(cos(-angle), -sin(-angle), sin(-angle), cos(-angle));
    vec2 back = inv_rot * transformed;
    
    // back should equal p
    float error = length(back - p);
    
    vec3 col = vec3(transformed * 0.5 + 0.5, clamp(error * 100.0, 0.0, 1.0));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

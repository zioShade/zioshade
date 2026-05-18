#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test split-screen comparison
void main() {
    float split = 0.5;
    float is_right = step(split, uv.x);
    
    // Left: grayscale
    float gray = sin(uv.x * 10.0 + uv.y * 8.0) * 0.5 + 0.5;
    vec3 left_col = vec3(gray);
    
    // Right: colorized
    vec3 right_col = vec3(
        sin(uv.x * 10.0) * 0.5 + 0.5,
        sin(uv.y * 8.0) * 0.5 + 0.5,
        sin(uv.x * 6.0 + uv.y * 6.0) * 0.5 + 0.5
    );
    
    vec3 col = mix(left_col, right_col, is_right);
    
    // Divider line
    float divider = smoothstep(0.003, 0.0, abs(uv.x - split));
    col = mix(col, vec3(1.0), divider);
    
    fragColor = vec4(col, 1.0);
}

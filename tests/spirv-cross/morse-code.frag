#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test morse code pattern (dots and dashes)
void main() {
    // Encode "GLSL" in morse: --. .-.. ... .-...
    // Each row is a different message
    float row = floor(uv.y * 6.0);
    float col = floor(uv.x * 30.0);
    float local_x = fract(uv.x * 30.0);
    float local_y = fract(uv.y * 6.0);
    
    // Dot = narrow bar, Dash = wide bar
    float symbol = 0.0;
    float r = fract(sin(row * 127.1 + col * 311.7) * 43758.5);
    
    // 40% dash, 30% dot, 30% gap
    float is_dash = step(r, 0.4);
    float is_dot = step(0.4, r) * step(r, 0.7);
    
    float dash_width = 0.8;
    float dot_width = 0.3;
    float width = is_dash * dash_width + is_dot * dot_width;
    float active = step(0.1, local_x) * step(local_x, 0.1 + width);
    float symbol_on = (is_dash + is_dot) * active;
    
    // Vertical centering
    float v_center = step(0.3, local_y) * step(local_y, 0.7);
    
    float pixel = symbol_on * v_center;
    
    vec3 bg = vec3(0.02);
    vec3 fg = vec3(0.1, 0.8, 0.1);
    
    vec3 col = mix(bg, fg, pixel);
    fragColor = vec4(col, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test digital rain (Matrix-style) pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec3 col = vec3(0.0);
    
    // Columns of falling characters
    float col_x = floor(uv.x * 40.0);
    float local_x = fract(uv.x * 40.0);
    
    // Each column has different speed and phase
    float col_h = hash(vec2(col_x, 0.0));
    float speed = 0.5 + col_h * 0.5;
    float phase = hash(vec2(col_x, 1.0));
    
    // Character positions in column
    float char_y = fract(uv.y * 20.0 + phase * 6.28);
    float char_id = floor(uv.y * 20.0 + phase * 6.28);
    
    // Lead character (brightest, at bottom of stream)
    float head_pos = mod(float(int(char_y * 8.0 + phase * 20.0)), 20.0);
    float is_head = smoothstep(0.1, 0.05, abs(char_y - 0.5));
    
    // Brightness fades with distance from head
    float brightness = smoothstep(0.0, 0.3, char_y) * step(char_y, 1.0);
    
    // Character shape: simplified block
    float char_shape = step(0.15, local_x) * step(local_x, 0.85) *
                       step(0.15, fract(uv.y * 20.0)) * step(fract(uv.y * 20.0), 0.85);
    
    // Green color with varying intensity
    float intensity = char_shape * brightness * step(0.3, col_h);
    vec3 bright_green = vec3(0.4, 1.0, 0.3);
    vec3 dim_green = vec3(0.05, 0.35, 0.05);
    
    col += dim_green * intensity;
    col += bright_green * intensity * is_head * 0.8;
    
    // Background glow from bright columns
    float glow = smoothstep(0.03, 0.0, abs(local_x - 0.5)) * step(0.7, col_h) * 0.02;
    col += glow * vec3(0.0, 0.3, 0.1);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

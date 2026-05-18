#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test spectral/frequency plot
void main() {
    float y = uv.y;
    float x = uv.x * 6.28 * 4.0;
    
    // Superposition of harmonics
    float wave = 0.0;
    wave += sin(x) * 0.5;
    wave += sin(x * 2.0 + 0.5) * 0.25;
    wave += sin(x * 3.0 + 1.0) * 0.125;
    wave += sin(x * 4.0 + 1.5) * 0.0625;
    
    // Normalize
    float normalized = wave * 0.8 + 0.5;
    
    // Draw wave line
    float d = abs(y - normalized);
    float line = smoothstep(0.02, 0.005, d);
    
    // Fill under curve
    float fill = step(y, normalized) * 0.2;
    
    vec3 col = vec3(0.05);
    col += fill * vec3(0.2, 0.4, 0.8);
    col += line * vec3(0.4, 0.8, 1.0);
    
    // Grid
    float grid_h = smoothstep(0.003, 0.0, abs(fract(y * 10.0) - 0.5) - 0.49);
    float grid_v = smoothstep(0.003, 0.0, abs(fract(uv.x * 10.0) - 0.5) - 0.49);
    col += max(grid_h, grid_v) * 0.1;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test audio visualizer / equalizer bars
void main() {
    int num_bars = 16;
    float bar_width = 1.0 / float(num_bars);
    int bar_idx = int(uv.x / bar_width);
    
    // Fake frequency data
    float freq = 0.0;
    for (int i = 0; i < 16; i++) {
        if (i == bar_idx) {
            freq = sin(float(i) * 0.5) * 0.5 + 0.5;
            freq *= 0.5 + 0.5 * cos(float(i) * 0.3);
            break;
        }
    }
    
    float bar_height = freq * 0.8 + 0.1;
    float local_x = fract(uv.x / bar_width);
    
    float in_bar = step(0.1, local_x) * step(local_x, 0.9);
    float bar_fill = step(uv.y, bar_height) * in_bar;
    
    // Color gradient based on height
    vec3 low_col = vec3(0.2, 0.5, 1.0);
    vec3 mid_col = vec3(0.2, 1.0, 0.3);
    vec3 high_col = vec3(1.0, 0.3, 0.1);
    
    vec3 bar_col;
    if (uv.y < 0.3) bar_col = low_col;
    else if (uv.y < 0.6) bar_col = mix(low_col, mid_col, (uv.y - 0.3) / 0.3);
    else bar_col = mix(mid_col, high_col, (uv.y - 0.6) / 0.4);
    
    vec3 col = vec3(0.02);
    col += bar_fill * bar_col;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

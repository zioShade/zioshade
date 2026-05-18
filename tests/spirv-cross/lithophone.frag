#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test stone lithophone / xylophone bars
void main() {
    int num_bars = 8;
    float bar_width = 1.0 / float(num_bars);
    int bar_idx = int(uv.x / bar_width);
    float local_x = fract(uv.x / bar_width);
    
    // Each bar has different height and color
    float heights[8];
    float fi = float(bar_idx);
    float bar_h = 0.3 + 0.5 * sin(fi * 0.8 + 0.5);
    
    // Stone texture
    float grain = sin(local_x * 50.0 + fi * 7.0) * 0.1;
    bar_h += grain;
    
    float in_bar = step(0.08, local_x) * step(local_x, 0.92);
    float bar_fill = step(uv.y, bar_h) * in_bar;
    
    // Stone colors per bar
    float h = fract(sin(fi * 127.1) * 43758.5);
    vec3 stone = mix(vec3(0.5, 0.45, 0.4), vec3(0.7, 0.65, 0.55), h);
    
    // Shadow under bar
    float shadow = step(uv.y, 0.02) * in_bar;
    
    // Support frame
    float frame_h = step(uv.y, 0.05) * step(0.03, uv.y);
    float frame_v1 = smoothstep(0.01, 0.0, abs(uv.x - 0.05));
    float frame_v2 = smoothstep(0.01, 0.0, abs(uv.x - 0.95));
    
    vec3 col = vec3(0.15);
    col += shadow * vec3(0.08);
    col += frame_h * vec3(0.3, 0.25, 0.2);
    col += (frame_v1 + frame_v2) * vec3(0.3, 0.25, 0.2);
    col += bar_fill * stone;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

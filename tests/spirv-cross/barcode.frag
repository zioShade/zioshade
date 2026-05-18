#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test barcode pattern
void main() {
    float y_top = 0.7;
    float y_bot = 0.3;
    float in_bar = step(y_bot, uv.y) * step(uv.y, y_top);
    
    // Generate barcode bars from pseudo-random sequence
    float x = uv.x * 50.0;
    float bar_id = floor(x);
    float bar_local = fract(x);
    
    // Pseudo-random width and presence
    float h = fract(sin(bar_id * 127.1) * 43758.5);
    float h2 = fract(sin(bar_id * 311.7) * 43758.5);
    
    // Bar present (80% of positions have a bar)
    float present = step(h2, 0.8);
    
    // Bar width (thin or thick)
    float width = step(h, 0.5) * 0.3 + step(0.5, h) * 0.7;
    
    float bar = step(0.0, bar_local) * step(bar_local, width) * present;
    
    // Guard bars (always present at start, center, end)
    float guard_start = step(uv.x, 0.06) * step(0.03, uv.x);
    float guard_center = step(0.47, uv.x) * step(uv.x, 0.53);
    float guard_end = step(0.94, uv.x) * step(uv.x, 0.97);
    float guard = max(max(guard_start, guard_center), guard_end);
    
    float pixel = max(bar * in_bar, guard * in_bar);
    
    // Numbers below barcode
    float num_band = step(0.2, uv.y) * step(uv.y, 0.27);
    
    vec3 white = vec3(1.0);
    vec3 black = vec3(0.05);
    
    vec3 col = white;
    col = mix(col, black, pixel);
    
    fragColor = vec4(col, 1.0);
}

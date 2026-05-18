#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test microchip/circuit board layout
void main() {
    vec2 p = uv * 16.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    // Grid of traces
    float trace_h = smoothstep(0.02, 0.0, abs(fp.y - 0.5)) * step(0.5, h);
    float trace_v = smoothstep(0.02, 0.0, abs(fp.x - 0.5)) * step(h, 0.3);
    
    // Via holes (circles at intersections)
    float via_dist = length(fp - 0.5);
    float via = smoothstep(0.12, 0.10, via_dist) * (1.0 - smoothstep(0.06, 0.05, via_dist));
    float via_pad = smoothstep(0.12, 0.10, via_dist);
    
    // IC chip in center
    float chip_x = step(4.0, id.x) * step(id.x, 11.0);
    float chip_y = step(6.0, id.y) * step(id.y, 9.0);
    float chip = chip_x * chip_y;
    float chip_inner = step(4.5, p.x) * step(p.x, 11.5) * step(6.5, p.y) * step(p.y, 9.5);
    
    // IC pins
    float pins = 0.0;
    for (int i = 5; i <= 11; i++) {
        float px = abs(fract(p.x) - (float(i) - floor(p.x) + fract(p.x)));
        float pin_top = smoothstep(0.02, 0.0, abs(p.y - 6.0)) * step(float(i), p.x) * step(p.x, float(i) + 0.8);
        float pin_bot = smoothstep(0.02, 0.0, abs(p.y - 9.0)) * step(float(i), p.x) * step(p.x, float(i) + 0.8);
        pins += pin_top + pin_bot;
    }
    
    vec3 board = vec3(0.05, 0.25, 0.05);
    vec3 trace = vec3(0.7, 0.6, 0.1);
    vec3 via_col = vec3(0.5, 0.5, 0.5);
    vec3 chip_col = vec3(0.15, 0.15, 0.15);
    
    vec3 col = board;
    col = mix(col, trace, max(trace_h, trace_v));
    col = mix(col, via_col, via_pad);
    col = mix(col, vec3(0.3), via);
    col = mix(col, chip_col, chip_inner);
    col += pins * vec3(0.8, 0.7, 0.2);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test circuit board pattern
void main() {
    vec2 p = uv * 12.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    // Traces (horizontal and vertical lines)
    float trace_h = smoothstep(0.02, 0.0, abs(fp.y - 0.5)) * step(0.5, h);
    float trace_v = smoothstep(0.02, 0.0, abs(fp.x - 0.5)) * step(h, 0.3);
    
    // Pads (circles at intersections)
    float pad = smoothstep(0.12, 0.10, length(fp - 0.5)) * step(0.6, h);
    
    // IC chip
    float chip_h = smoothstep(0.1, 0.15, fp.x) * (1.0 - smoothstep(0.85, 0.9, fp.x));
    float chip_v = smoothstep(0.2, 0.25, fp.y) * (1.0 - smoothstep(0.75, 0.8, fp.y));
    float chip = chip_h * chip_v * step(h, 0.2);
    
    vec3 board = vec3(0.1, 0.3, 0.1);
    vec3 trace = vec3(0.7, 0.6, 0.1);
    vec3 pad_col = vec3(0.8, 0.7, 0.2);
    vec3 chip_col = vec3(0.2, 0.2, 0.2);
    
    vec3 col = board;
    col = mix(col, trace, max(trace_h, trace_v));
    col = mix(col, pad_col, pad);
    col = mix(col, chip_col, chip);
    
    fragColor = vec4(col, 1.0);
}

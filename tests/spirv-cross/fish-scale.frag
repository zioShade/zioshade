#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test fish scale pattern
void main() {
    vec2 p = uv * 12.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Offset every other row for overlapping scales
    float row_offset = mod(id.y, 2.0) * 0.5;
    fp.x = fract(fp.x + row_offset);
    
    // Scale shape: arc (half circle) facing up
    vec2 center = vec2(0.5, 0.0);
    float d = length(fp - center);
    float scale_shape = smoothstep(0.55, 0.52, d) * step(0.0, fp.y - 0.05);
    
    // Scale inner ring
    float ring = smoothstep(0.4, 0.38, d) * (1.0 - smoothstep(0.35, 0.33, d));
    ring *= step(0.1, fp.y);
    
    // Color per scale
    float h = fract(sin(dot(id + vec2(row_offset, 0.0), vec2(127.1, 311.7))) * 43758.5);
    vec3 scale_col = mix(vec3(0.2, 0.5, 0.7), vec3(0.4, 0.7, 0.6), h);
    vec3 ring_col = scale_col * 1.3;
    vec3 dark = scale_col * 0.5;
    
    // Depth: scales overlap upward
    float shade = smoothstep(0.0, 0.5, fp.y);
    
    vec3 col = vec3(0.03, 0.05, 0.08);
    col = mix(col, dark * (0.6 + shade * 0.4), scale_shape);
    col = mix(col, ring_col, ring * scale_shape);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

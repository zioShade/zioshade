#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Celtic knot pattern (interlocking loops)
void main() {
    vec2 p = uv * 6.0;
    vec2 id = floor(p);
    vec2 fp = fract(p) - 0.5;
    
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    // Four arc segments per cell (quarter circles at corners)
    float line_w = 0.06;
    float knot = 0.0;
    
    // Arc at each corner: center at (±0.5, ±0.5)
    for (int cx = 0; cx < 2; cx++) {
        for (int cy = 0; cy < 2; cy++) {
            vec2 corner = vec2(float(cx) * 2.0 - 0.5, float(cy) * 2.0 - 0.5);
            float d = length(fp - corner);
            float arc = smoothstep(line_w, line_w - 0.02, abs(d - 0.35));
            
            // Only draw the quarter facing center
            vec2 to_center = -corner;
            vec2 to_point = fp - corner;
            float facing = step(0.0, dot(normalize(to_center), normalize(to_point)));
            arc *= facing;
            
            knot += arc;
        }
    }
    
    // Over-under: at crossings, alternate which goes over
    knot = min(knot, 1.0);
    
    // Background
    vec3 bg = vec3(0.12, 0.14, 0.1);
    vec3 rope = vec3(0.85, 0.75, 0.55);
    vec3 shadow = vec3(0.5, 0.45, 0.35);
    
    vec3 col = bg + knot * rope;
    
    // Subtle border between cells
    float border = step(0.48, abs(fp.x)) + step(0.48, abs(fp.y));
    col = mix(col, bg * 0.8, min(border, 1.0) * 0.3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

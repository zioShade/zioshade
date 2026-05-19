#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Celtic cross pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Cross arms (equal length, wide)
    float arm_w = 0.05;
    float arm_l = 0.32;
    float cross_h = smoothstep(arm_w, arm_w - 0.005, abs(p.x)) * step(-arm_l, p.y) * step(p.y, arm_l);
    float cross_v = smoothstep(arm_w, arm_w - 0.005, abs(p.y)) * step(-arm_l, p.x) * step(p.x, arm_l);
    float cross = max(cross_h, cross_v);
    
    // Circle around the intersection
    float circle = smoothstep(0.15, 0.145, r) * (1.0 - smoothstep(0.13, 0.125, r));
    
    // Knotwork: interlocking arcs in the quadrants
    float knot = 0.0;
    float line_w = 0.012;
    
    // Top-right quadrant arcs
    vec2 q1 = p - vec2(0.1, 0.1);
    float d1 = length(q1);
    knot += smoothstep(line_w, line_w - 0.003, abs(d1 - 0.06)) * step(0.0, q1.x) * step(0.0, q1.y);
    
    // Top-left
    vec2 q2 = p - vec2(-0.1, 0.1);
    float d2 = length(q2);
    knot += smoothstep(line_w, line_w - 0.003, abs(d2 - 0.06)) * step(q2.x, 0.0) * step(0.0, q2.y);
    
    // Bottom-right
    vec2 q3 = p - vec2(0.1, -0.1);
    float d3 = length(q3);
    knot += smoothstep(line_w, line_w - 0.003, abs(d3 - 0.06)) * step(0.0, q3.x) * step(q3.y, 0.0);
    
    // Bottom-left
    vec2 q4 = p - vec2(-0.1, -0.1);
    float d4 = length(q4);
    knot += smoothstep(line_w, line_w - 0.003, abs(d4 - 0.06)) * step(q4.x, 0.0) * step(q4.y, 0.0);
    
    // Background
    vec3 bg = vec3(0.06, 0.08, 0.15);
    vec3 stone = vec3(0.75, 0.72, 0.65);
    vec3 knot_col = vec3(0.6, 0.55, 0.45);
    vec3 circle_col = vec3(0.65, 0.6, 0.5);
    
    vec3 col = bg;
    col = mix(col, stone, cross);
    col = mix(col, circle_col, circle);
    col = mix(col, knot_col, min(knot, 1.0));
    
    // Subtle glow
    float glow = exp(-r * r * 10.0) * 0.1;
    col += glow * vec3(0.4, 0.5, 0.7);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

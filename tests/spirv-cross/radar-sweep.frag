#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test radar sweep pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Sweep angle (using uv.x as time proxy)
    float sweep_angle = uv.x * 6.28;
    
    // Angular difference
    float angle_diff = mod(a - sweep_angle + 3.14159, 6.28318) - 3.14159;
    
    // Sweep trail
    float trail = smoothstep(-1.0, 0.0, angle_diff) * smoothstep(0.5, 0.0, angle_diff);
    
    // Range rings
    float rings = smoothstep(0.02, 0.0, abs(fract(r * 4.0) - 0.5) - 0.45);
    
    // Cross hairs
    float cross_h = smoothstep(0.005, 0.0, abs(p.y));
    float cross_v = smoothstep(0.005, 0.0, abs(p.x));
    
    float grid = max(max(rings, cross_h), cross_v);
    
    // Dots (targets)
    float t1 = smoothstep(0.02, 0.01, length(p - vec2(0.15, 0.1)));
    float t2 = smoothstep(0.02, 0.01, length(p - vec2(-0.2, -0.05)));
    
    vec3 col = vec3(0.0, 0.08, 0.0);
    col += trail * vec3(0.0, 0.5, 0.0) * (1.0 - smoothstep(0.45, 0.5, r));
    col += grid * vec3(0.0, 0.3, 0.0);
    col += (t1 + t2) * vec3(0.0, 0.8, 0.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

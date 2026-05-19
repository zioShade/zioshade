#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test pendulum wave pattern
void main() {
    vec3 col = vec3(0.02);
    
    // Row of pendulums
    int num = 16;
    for (int i = 0; i < 16; i++) {
        float fi = float(i);
        float x_pos = (fi + 0.5) / float(num);
        
        // Each pendulum swings with slightly different frequency
        float phase = fi * 0.4;
        float swing = sin(phase) * 0.04;
        
        // Pendulum bob position
        vec2 bob = vec2(x_pos + swing, 0.6 - abs(swing) * 2.0);
        float d = length(uv - bob);
        float bob_shape = smoothstep(0.018, 0.014, d);
        
        // String from pivot to bob
        float pivot_x = x_pos;
        float pivot_y = 0.85;
        float dx = bob.x - pivot_x;
        float dy = bob.y - pivot_y;
        float len = length(vec2(dx, dy));
        float t = clamp(dot(uv - vec2(pivot_x, pivot_y), vec2(dx, dy)) / (len * len), 0.0, 1.0);
        float line_dist = length(uv - (vec2(pivot_x, pivot_y) + t * vec2(dx, dy)));
        float string = smoothstep(0.003, 0.001, line_dist) * step(t, 1.0);
        
        // Color by position
        float t2 = fi / float(num);
        vec3 bob_col = mix(vec3(0.9, 0.3, 0.2), vec3(0.2, 0.5, 0.9), t2);
        
        col += string * vec3(0.5);
        col = mix(col, bob_col, bob_shape);
    }
    
    // Top bar
    float bar = smoothstep(0.01, 0.005, abs(uv.y - 0.85)) * step(0.02, uv.x) * step(uv.x, 0.98);
    col += bar * vec3(0.4);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

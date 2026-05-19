#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test dragon curve fractal via L-system approximation
void main() {
    vec2 p = uv - 0.5;
    p = p * 2.0;
    
    // Dragon curve: repeated folding pattern
    float line = 1.0;
    float scale = 1.0;
    vec2 offset = vec2(0.0);
    
    // Approximate dragon curve with iterative corner detection
    for (int i = 0; i < 8; i++) {
        // Fold: rotate upper-right quadrant
        vec2 q = p;
        float fold_x = step(0.0, q.x);
        float fold_y = step(0.0, q.y);
        
        // Distance to fold lines
        float dx = abs(q.x);
        float dy = abs(q.y);
        float d = min(dx, dy);
        
        line = min(line, d / scale);
        
        // Fold transformation
        float s = 1.0;
        if (q.x > 0.0 && q.y > 0.0) {
            p = vec2(q.y, -q.x) * 0.5;
        } else if (q.x > 0.0) {
            p = vec2(q.y + 1.0, q.x) * 0.5;
        } else if (q.y > 0.0) {
            p = vec2(-q.y, q.x - 1.0) * 0.5;
        } else {
            p = vec2(-q.y - 1.0, -q.x) * 0.5;
        }
        scale *= 0.5;
    }
    
    // Render as thin line
    float thickness = 0.02;
    float curve = smoothstep(thickness, thickness - 0.005, line);
    
    // Color gradient along the curve
    vec3 col = vec3(0.02, 0.01, 0.05);
    vec3 curve_col = vec3(0.8, 0.3, 0.9);
    col += curve * curve_col;
    
    // Glow
    col += exp(-line * 10.0) * vec3(0.3, 0.1, 0.4) * 0.3;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

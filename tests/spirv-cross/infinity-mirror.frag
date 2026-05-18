#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test infinity mirror effect (recursive frame within frame)
void main() {
    vec2 p = uv - 0.5;
    
    vec3 col = vec3(0.0);
    float brightness = 1.0;
    
    // Each iteration adds a smaller frame
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float scale = pow(0.6, fi);
        vec2 q = p / scale;
        
        // Frame rectangle
        float frame_x = max(abs(q.x) - 0.4, 0.0);
        float frame_y = max(abs(q.y) - 0.4, 0.0);
        float frame_outer = sqrt(frame_x * frame_x + frame_y * frame_y);
        
        float inner_x = max(abs(q.x) - 0.35, 0.0);
        float inner_y = max(abs(q.y) - 0.35, 0.0);
        float frame_inner = sqrt(inner_x * inner_x + inner_y * inner_y);
        
        float frame = smoothstep(0.06, 0.04, frame_outer) * (1.0 - smoothstep(0.01, 0.0, frame_inner));
        
        // Color shifts per depth
        vec3 frame_col;
        float t = fi / 6.0;
        if (t < 0.33) frame_col = vec3(0.7, 0.5, 0.3);
        else if (t < 0.66) frame_col = vec3(0.5, 0.3, 0.7);
        else frame_col = vec3(0.3, 0.6, 0.7);
        
        col += frame * frame_col * brightness;
        brightness *= 0.7;
    }
    
    // Center glow (LED light illusion)
    float glow = exp(-dot(p, p) * 8.0);
    col += glow * vec3(0.3, 0.5, 0.9) * 0.5;
    
    // Dark reflective background
    col *= 1.2;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

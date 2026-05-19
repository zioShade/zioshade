#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Newton's cradle pattern
void main() {
    vec3 col = vec3(0.12, 0.12, 0.15);
    
    // Frame: two A-frame supports + top bar
    float frame_left = smoothstep(0.008, 0.003, abs(uv.x - (0.15 + (uv.y - 0.2) * 0.15)));
    float frame_right = smoothstep(0.008, 0.003, abs(uv.x - (0.85 - (uv.y - 0.2) * 0.15)));
    float frame_mask = step(0.2, uv.y) * smoothstep(0.75, 0.73, uv.y);
    col += (frame_left + frame_right) * frame_mask * vec3(0.5, 0.5, 0.55);
    
    // Top bar
    float bar = smoothstep(0.008, 0.003, abs(uv.y - 0.73)) * step(0.12, uv.x) * step(uv.x, 0.88);
    col += bar * vec3(0.5, 0.5, 0.55);
    
    // Base
    float base = step(uv.y, 0.22) * smoothstep(0.2, 0.22, uv.y) * step(0.08, uv.x) * step(uv.x, 0.92);
    col = mix(col, vec3(0.3, 0.3, 0.35), base);
    
    // 5 balls hanging from strings
    int num_balls = 5;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float x_pos = 0.3 + fi * 0.1;
        
        // Left ball swung out
        float swing = 0.0;
        if (i == 0) swing = 0.06;
        if (i == 4) swing = -0.06; // right ball swung out
        
        float bob_x = x_pos + swing;
        float bob_y = 0.5;
        float bob_r = 0.028;
        
        // String
        float dx = bob_x - x_pos;
        float dy = bob_y - 0.73;
        float len = length(vec2(dx, dy));
        float t = clamp(dot(uv - vec2(x_pos, 0.73), vec2(dx, dy)) / (len * len), 0.0, 1.0);
        float line_dist = length(uv - (vec2(x_pos, 0.73) + t * vec2(dx, dy)));
        float string = smoothstep(0.003, 0.001, line_dist);
        col += string * vec3(0.4);
        
        // Ball (sphere shading)
        float d = length(uv - vec2(bob_x, bob_y));
        float ball = smoothstep(bob_r, bob_r - 0.003, d);
        float shade = smoothstep(bob_r, 0.0, d);
        vec3 ball_col = vec3(0.7, 0.72, 0.75) * (0.4 + 0.6 * shade);
        // Highlight
        float hl = exp(-length(uv - vec2(bob_x - 0.008, bob_y + 0.008)) * 50.0) * 0.4;
        ball_col += hl;
        col = mix(col, ball_col, ball);
    }
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

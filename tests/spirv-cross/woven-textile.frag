#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test woven textile / over-under weave pattern
void main() {
    vec2 p = uv * 16.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    // Warp and weft threads
    float thread_w = 0.3;
    
    // Horizontal threads (weft)
    float h_center = 0.5;
    float h_dist = abs(fp.y - h_center);
    float h_thread = smoothstep(thread_w, thread_w - 0.05, h_dist);
    
    // Vertical threads (warp)
    float v_center = 0.5;
    float v_dist = abs(fp.x - v_center);
    float v_thread = smoothstep(thread_w, thread_w - 0.05, v_dist);
    
    // Over-under pattern: checkerboard determines which is on top
    float over = mod(id.x + id.y, 2.0);
    
    // Thread colors per row/column
    float h_color = fract(sin(id.y * 127.1) * 43758.5);
    float v_color = fract(sin(id.x * 311.7) * 43758.5);
    
    vec3 weft_col = mix(vec3(0.7, 0.2, 0.15), vec3(0.85, 0.75, 0.3), h_color);
    vec3 warp_col = mix(vec3(0.15, 0.2, 0.7), vec3(0.2, 0.6, 0.3), v_color);
    
    // Draw threads with depth ordering
    vec3 col = vec3(0.08);
    
    if (over > 0.5) {
        col = mix(col, warp_col, v_thread);
        col = mix(col, weft_col, h_thread);
    } else {
        col = mix(col, weft_col, h_thread);
        col = mix(col, warp_col, v_thread);
    }
    
    // Shadow at crossings
    float crossing = h_thread * v_thread;
    col *= 1.0 - crossing * 0.15;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

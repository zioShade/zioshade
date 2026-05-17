#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test woven fabric pattern
void main() {
    vec2 p = uv * 12.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Horizontal and vertical threads
    float h_thread = smoothstep(0.1, 0.15, fp.y) * (1.0 - smoothstep(0.85, 0.9, fp.y));
    float v_thread = smoothstep(0.1, 0.15, fp.x) * (1.0 - smoothstep(0.85, 0.9, fp.x));
    
    // Over-under pattern
    float over_h = step(0.5, fract(id.x * 0.5 + id.y * 0.5));
    float over_v = 1.0 - over_h;
    
    // Thread colors
    float hc = fract(sin(dot(id, vec2(127.1, 0.0))) * 43758.5);
    float vc = fract(sin(dot(id, vec2(0.0, 311.7))) * 43758.5);
    
    vec3 h_col = mix(vec3(0.6, 0.2, 0.2), vec3(0.8, 0.3, 0.3), hc);
    vec3 v_col = mix(vec3(0.2, 0.2, 0.6), vec3(0.3, 0.3, 0.8), vc);
    
    vec3 col = vec3(0.08);
    if (over_h > 0.5) {
        col = mix(col, h_col, h_thread);
        col = mix(col, v_col, v_thread * (1.0 - h_thread));
    } else {
        col = mix(col, v_col, v_thread);
        col = mix(col, h_col, h_thread * (1.0 - v_thread));
    }
    
    fragColor = vec4(col, 1.0);
}

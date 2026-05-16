#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Fabric/weave pattern
void main() {
    vec2 p = uv * 20.0;
    
    // Horizontal and vertical threads
    float h_thread = smoothstep(0.4, 0.5, fract(p.y));
    float v_thread = smoothstep(0.4, 0.5, fract(p.x));
    
    // Over-under weaving
    float h_idx = floor(p.x);
    float v_idx = floor(p.y);
    float over = mod(h_idx + v_idx, 2.0);
    
    vec3 col_h = vec3(0.6, 0.2, 0.1);
    vec3 col_v = vec3(0.1, 0.2, 0.6);
    
    vec3 col = mix(col_h, col_v, over * v_thread + (1.0 - over) * h_thread);
    
    fragColor = vec4(col, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Penrose impossible triangle
void main() {
    vec3 col = vec3(0.95, 0.93, 0.9);
    
    vec2 p = uv - vec2(0.5, 0.48);
    
    float beam_w = 0.045;
    float beam_l = 0.28;
    
    vec3 c_red = vec3(0.8, 0.3, 0.2);
    vec3 c_blue = vec3(0.2, 0.5, 0.8);
    vec3 c_green = vec3(0.3, 0.7, 0.3);
    
    // Beam 1: goes up-right
    float b1_perp = abs(-p.x * 0.5 + p.y * 0.866);
    float b1_along = p.x * 0.866 + p.y * 0.5;
    float bm1 = smoothstep(beam_w, beam_w - 0.003, b1_perp) * step(0.0, b1_along) * smoothstep(beam_l, beam_l - 0.005, b1_along);
    
    // Beam 2: goes right-down
    float b2_perp = abs(p.x * 0.5 + p.y * 0.866);
    float b2_along = p.x * 0.866 - p.y * 0.5;
    float bm2 = smoothstep(beam_w, beam_w - 0.003, b2_perp) * step(0.0, b2_along) * smoothstep(beam_l, beam_l - 0.005, b2_along);
    
    // Beam 3: goes left
    float b3_perp = abs(p.y);
    float b3_along = -p.x;
    float bm3 = smoothstep(beam_w, beam_w - 0.003, b3_perp) * step(0.0, b3_along) * smoothstep(beam_l, beam_l - 0.005, b3_along);
    
    col = mix(col, c_red * 0.85, bm1);
    col = mix(col, c_blue * 0.9, bm2);
    col = mix(col, c_green * 0.95, bm3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

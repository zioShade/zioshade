#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test bonsai tree with pot and trunk
void main() {
    vec3 col = vec3(0.9, 0.92, 0.88); // light background
    
    // Pot (trapezoid)
    float pot_top = 0.35;
    float pot_bot = 0.2;
    float pot_left_top = 0.38;
    float pot_right_top = 0.62;
    float pot_left_bot = 0.35;
    float pot_right_bot = 0.65;
    
    float py = clamp((uv.y - pot_bot) / (pot_top - pot_bot), 0.0, 1.0);
    float pl = mix(pot_left_bot, pot_left_top, py);
    float pr = mix(pot_right_bot, pot_right_top, py);
    float pot = step(pl, uv.x) * step(uv.x, pr) * step(pot_bot, uv.y) * step(uv.y, pot_top);
    
    // Pot rim
    float rim = step(pot_top, uv.y) * step(uv.y, pot_top + 0.02) * step(pot_left_top - 0.02, uv.x) * step(uv.x, pot_right_top + 0.02);
    
    vec3 pot_col = vec3(0.7, 0.35, 0.2);
    vec3 rim_col = vec3(0.6, 0.3, 0.15);
    col = mix(col, pot_col, pot);
    col = mix(col, rim_col, rim);
    
    // Soil
    float soil = step(pot_top - 0.01, uv.y) * step(uv.y, pot_top + 0.005) * step(pot_left_top + 0.01, uv.x) * step(uv.x, pot_right_top - 0.01);
    col = mix(col, vec3(0.35, 0.25, 0.15), soil);
    
    // Trunk (curved brown shape)
    vec2 tp = uv - vec2(0.48, 0.35);
    float trunk = smoothstep(0.025, 0.02, abs(tp.x + tp.y * 0.3)) * step(0.35, uv.y) * smoothstep(0.7, 0.65, uv.y);
    vec3 bark = vec3(0.35, 0.25, 0.15);
    col = mix(col, bark, trunk);
    
    // Branches (thinner lines going outward)
    float branch1 = smoothstep(0.008, 0.004, abs((uv.x - 0.48) - (uv.y - 0.6) * 0.6)) * step(0.55, uv.y) * step(uv.y, 0.7) * step(uv.x, 0.48);
    float branch2 = smoothstep(0.008, 0.004, abs((uv.x - 0.48) + (uv.y - 0.6) * 0.4)) * step(0.55, uv.y) * step(uv.y, 0.72) * step(0.48, uv.x);
    col = mix(col, bark, max(branch1, branch2));
    
    // Foliage clouds (overlapping green circles)
    float foliage = 0.0;
    vec2 foliage_positions[8];
    foliage_positions[0] = vec2(0.38, 0.62);
    foliage_positions[1] = vec2(0.48, 0.68);
    foliage_positions[2] = vec2(0.58, 0.65);
    foliage_positions[3] = vec2(0.43, 0.72);
    foliage_positions[4] = vec2(0.55, 0.72);
    foliage_positions[5] = vec2(0.48, 0.76);
    foliage_positions[6] = vec2(0.35, 0.58);
    foliage_positions[7] = vec2(0.62, 0.6);
    
    for (int i = 0; i < 8; i++) {
        float fd = length(uv - foliage_positions[i]);
        float f = smoothstep(0.08, 0.05, fd);
        // Shading: darker at edges
        float f_shade = smoothstep(0.08, 0.02, fd);
        vec3 leaf_col = vec3(0.15, 0.45, 0.12) * (0.6 + 0.4 * f_shade);
        col = mix(col, leaf_col, f);
    }
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

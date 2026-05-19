#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test pie chart data visualization
void main() {
    vec2 p = uv - vec2(0.5, 0.55);
    float r = length(p);
    float a = atan(p.y, p.x) + 3.14159;
    float norm_a = a / 6.28318;
    
    // Pie slices (4 segments)
    float slice1 = step(norm_a, 0.35);         // 35%
    float slice2 = step(0.35, norm_a) * step(norm_a, 0.55); // 20%
    float slice3 = step(0.55, norm_a) * step(norm_a, 0.80); // 25%
    float slice4 = step(0.80, norm_a);          // 20%
    
    vec3 c1 = vec3(0.85, 0.25, 0.2);
    vec3 c2 = vec3(0.2, 0.6, 0.85);
    vec3 c3 = vec3(0.3, 0.8, 0.3);
    vec3 c4 = vec3(0.95, 0.75, 0.2);
    
    vec3 slice_col = c1 * slice1 + c2 * slice2 + c3 * slice3 + c4 * slice4;
    
    // Pie circle
    float pie = smoothstep(0.3, 0.29, r);
    float hole = smoothstep(0.08, 0.07, r);
    
    // Divider lines
    float div = 0.0;
    float angles[4];
    angles[0] = 0.0;
    angles[1] = 0.35 * 6.28318 - 3.14159;
    angles[2] = 0.55 * 6.28318 - 3.14159;
    angles[3] = 0.80 * 6.28318 - 3.14159;
    for (int i = 0; i < 4; i++) {
        float da = atan(p.y, p.x) - angles[i];
        da = abs(da);
        da = min(da, 6.2832 - da);
        div += smoothstep(0.015, 0.005, da) * step(0.08, r) * smoothstep(0.3, 0.28, r);
    }
    
    vec3 bg = vec3(0.95);
    vec3 col = bg;
    col = mix(col, slice_col, pie * (1.0 - hole));
    col = mix(col, bg, hole * pie);
    col = mix(col, vec3(0.2), min(div, 1.0));
    
    // Legend
    float legend_x = step(0.05, uv.x) * step(uv.x, 0.12);
    float l1 = legend_x * step(0.02, uv.y) * step(uv.y, 0.06);
    float l2 = legend_x * step(0.07, uv.y) * step(uv.y, 0.11);
    col = mix(col, c1, l1);
    col = mix(col, c2, l2);
    
    fragColor = vec4(col, 1.0);
}

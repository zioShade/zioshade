#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// 2D metaballs
void main() {
    vec2 p = uv * 3.0;
    
    // Metaball field
    float field = 0.0;
    field += 1.0 / (length(p - vec2(1.5, 1.5)) + 0.01);
    field += 1.0 / (length(p - vec2(1.0, 2.0)) + 0.01);
    field += 0.8 / (length(p - vec2(2.2, 1.2)) + 0.01);
    
    float threshold = 4.0;
    float edge = smoothstep(threshold - 0.5, threshold + 0.5, field);
    
    vec3 bg = vec3(0.05, 0.05, 0.1);
    vec3 ball_col = vec3(0.2, 0.5, 0.9);
    vec3 highlight = vec3(0.8, 0.9, 1.0);
    
    vec3 col = mix(bg, ball_col, edge);
    col += highlight * smoothstep(threshold + 2.0, threshold + 6.0, field) * 0.3;
    
    fragColor = vec4(col, 1.0);
}

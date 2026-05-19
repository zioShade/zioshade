#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test halftone printing pattern
void main() {
    vec2 p = uv * 24.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Source image: simple gradient + circle
    vec2 cp = uv - 0.5;
    float r = length(cp);
    float gradient = uv.y;
    float circle = smoothstep(0.2, 0.15, r);
    float brightness = gradient * 0.6 + circle * 0.4;
    
    // Halftone: dot size proportional to darkness
    float dot_size = (1.0 - brightness) * 0.45 + 0.02;
    float d = length(fp - 0.5);
    float dot = smoothstep(dot_size, dot_size - 0.03, d);
    
    // CMYK-like coloring by offsetting grids
    // Cyan layer (offset right)
    vec2 p_c = (uv + vec2(0.01, 0.0)) * 24.0;
    vec2 id_c = floor(p_c);
    vec2 fp_c = fract(p_c);
    float d_c = length(fp_c - 0.5);
    float dot_c = smoothstep(dot_size * 0.9, dot_size * 0.9 - 0.03, d_c) * step(0.3, brightness);
    
    // Magenta layer (offset up)
    vec2 p_m = (uv + vec2(0.0, 0.01)) * 24.0;
    vec2 fp_m = fract(p_m);
    float d_m = length(fp_m - 0.5);
    float dot_m = smoothstep(dot_size * 0.85, dot_size * 0.85 - 0.03, d_m) * step(0.5, brightness);
    
    vec3 paper = vec3(0.95, 0.93, 0.9);
    vec3 ink = vec3(0.05);
    
    vec3 col = paper;
    col = mix(col, vec3(0.1), dot * 0.7);
    col = mix(col, vec3(0.1, 0.3, 0.5), dot_c * 0.3);
    col = mix(col, vec3(0.5, 0.1, 0.3), dot_m * 0.2);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

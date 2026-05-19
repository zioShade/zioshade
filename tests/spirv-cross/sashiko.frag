#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test sashiko pattern (Japanese running stitch embroidery)
void main() {
    // Indigo fabric background
    vec3 col = vec3(0.08, 0.12, 0.3);
    
    // Fabric texture
    float tex = fract(sin(dot(floor(uv * 300.0), vec2(12.9, 78.2))) * 43758.5);
    col += (tex - 0.5) * 0.02;
    
    // Sashiko: running stitch patterns
    vec3 thread = vec3(0.92, 0.88, 0.82);
    float stitch_w = 0.004;
    
    // Hitomezashi (grid-based) pattern: alternating dashes
    float grid = 12.0;
    vec2 p = uv * grid;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Horizontal stitches: on/off based on column parity
    float h_stitch = 0.0;
    float h_on = step(0.5, fract(sin(id.x * 1.7) * 43758.5));
    h_stitch = smoothstep(stitch_w * grid, stitch_w * grid - 0.5, abs(fp.x - 0.5)) * 
               step(0.15, fp.y) * step(fp.y, 0.85) * h_on;
    
    // Vertical stitches: on/off based on row parity
    float v_stitch = 0.0;
    float v_on = step(0.5, fract(sin(id.y * 2.3) * 43758.5));
    v_stitch = smoothstep(stitch_w * grid, stitch_w * grid - 0.5, abs(fp.y - 0.5)) * 
               step(0.15, fp.x) * step(fp.x, 0.85) * v_on;
    
    col = mix(col, thread, max(h_stitch, v_stitch));
    
    // Intersections get a small dot
    float dot_mask = h_on * v_on;
    float dot_d = length(fp - 0.5);
    float cross_dot = smoothstep(0.08, 0.05, dot_d) * dot_mask;
    col = mix(col, thread, cross_dot);
    
    // Vignette
    float vig = 1.0 - dot(uv - 0.5, uv - 0.5) * 0.5;
    col *= vig;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

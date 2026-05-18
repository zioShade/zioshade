#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test depth-of-field / bokeh simulation
void main() {
    // In-focus region (center circle)
    float focus_dist = length(uv - vec2(0.5, 0.4));
    
    // Defocus amount
    float blur = smoothstep(0.1, 0.35, focus_dist);
    
    // Sharp dots pattern
    float d1 = smoothstep(0.03, 0.02, length(uv - vec2(0.3, 0.4)));
    float d2 = smoothstep(0.03, 0.02, length(uv - vec2(0.5, 0.35)));
    float d3 = smoothstep(0.03, 0.02, length(uv - vec2(0.7, 0.45)));
    
    // Bokeh circles (defocused highlights)
    float b1 = smoothstep(0.08, 0.06, length(uv - vec2(0.2, 0.6))) * blur;
    float b2 = smoothstep(0.06, 0.04, length(uv - vec2(0.6, 0.7))) * blur;
    float b3 = smoothstep(0.1, 0.08, length(uv - vec2(0.8, 0.3))) * blur;
    float b4 = smoothstep(0.05, 0.03, length(uv - vec2(0.4, 0.8))) * blur;
    
    vec3 bg = vec3(0.05, 0.05, 0.1);
    vec3 dot_col = vec3(1.0, 0.8, 0.3);
    vec3 bokeh_col = vec3(0.8, 0.9, 1.0);
    
    vec3 col = bg;
    col += (d1 + d2 + d3) * dot_col;
    col += (b1 + b2 + b3 + b4) * bokeh_col;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

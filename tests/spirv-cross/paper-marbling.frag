#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test paper marbling pattern
void main() {
    vec2 p = uv * 4.0;
    
    // Marbling: distorted sine waves layered
    float pattern = 0.0;
    
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float freq = 2.0 + fi * 1.5;
        float phase = fi * 1.23;
        float amp = 0.3 / (1.0 + fi * 0.5);
        
        // Distortion from other layers
        float distort_x = sin(p.y * (3.0 + fi) + phase) * amp;
        float distort_y = cos(p.x * (2.0 + fi) + phase * 0.7) * amp * 0.5;
        
        vec2 dp = p + vec2(distort_x, distort_y);
        float wave = sin(dp.x * freq + phase) * 0.5 + 0.5;
        pattern += wave * (1.0 / (1.0 + fi * 0.3));
    }
    
    pattern = pattern / 3.5;
    
    // Marbling color palette
    vec3 col1 = vec3(0.85, 0.2, 0.15);
    vec3 col2 = vec3(0.95, 0.85, 0.6);
    vec3 col3 = vec3(0.15, 0.3, 0.7);
    vec3 col4 = vec3(0.1, 0.5, 0.3);
    
    vec3 col;
    if (pattern < 0.25) col = mix(col1, col2, pattern / 0.25);
    else if (pattern < 0.5) col = mix(col2, col3, (pattern - 0.25) / 0.25);
    else if (pattern < 0.75) col = mix(col3, col4, (pattern - 0.5) / 0.25);
    else col = mix(col4, col1, (pattern - 0.75) / 0.25);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

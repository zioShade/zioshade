#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test rising bubble simulation
void main() {
    vec3 col = vec3(0.02, 0.02, 0.06);
    
    // Multiple bubbles at different positions
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float h = fract(sin(fi * 127.1) * 43758.5);
        float h2 = fract(sin(fi * 311.7) * 43758.5);
        
        // Bubble position (rises with uv.x as time proxy)
        float bx = h * 0.8 + 0.1;
        float by = fract(h2 + uv.x * 0.5);
        
        vec2 bubble_pos = vec2(bx, by * 0.7 + 0.15);
        float d = length(uv - bubble_pos);
        float size = 0.03 + h * 0.04;
        
        // Bubble shape
        float bubble = smoothstep(size, size - 0.005, d);
        
        // Iridescent surface
        float iri = sin(d * 60.0 + fi * 2.0) * 0.5 + 0.5;
        vec3 bubble_col = mix(vec3(0.3, 0.5, 0.9), vec3(0.6, 0.3, 0.8), iri);
        
        // Specular highlight
        vec2 hl = uv - bubble_pos + vec2(0.008, 0.01);
        float spec = exp(-dot(hl, hl) / (size * size * 0.5)) * 0.6;
        
        col += bubble * bubble_col * 0.3;
        col += spec * bubble;
    }
    
    // Liquid surface at top
    float surface = smoothstep(0.92, 0.9, uv.y) * (1.0 - smoothstep(0.88, 0.9, uv.y));
    col += surface * vec3(0.1, 0.15, 0.3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

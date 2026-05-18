#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test origami folded paper pattern
void main() {
    vec2 p = uv * 6.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    // Diagonal fold direction per tile
    float diag = step(h, 0.5);
    float d1 = diag * abs(fp.x - fp.y) + (1.0 - diag) * abs(fp.x + fp.y - 1.0);
    
    // Shade based on which side of fold
    float side = diag * step(fp.x, fp.y) + (1.0 - diag) * step(1.0 - fp.x, fp.y);
    
    // Paper colors
    vec3 paper_a = vec3(0.9, 0.85, 0.8);
    vec3 paper_b = vec3(0.7, 0.65, 0.6);
    vec3 shadow = vec3(0.55, 0.5, 0.45);
    
    vec3 col = mix(paper_a, paper_b, side);
    
    // Fold line
    float fold = smoothstep(0.015, 0.005, d1);
    col = mix(col, shadow, fold);
    
    // Crease shadow
    float crease = smoothstep(0.04, 0.01, d1) * (1.0 - fold);
    col = mix(col, col * 0.85, crease);
    
    // Edge darkening
    float edge = 1.0 - step(0.02, fp.x) * step(fp.x, 0.98) *
                        step(0.02, fp.y) * step(fp.y, 0.98);
    col = mix(col, vec3(0.3), edge);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

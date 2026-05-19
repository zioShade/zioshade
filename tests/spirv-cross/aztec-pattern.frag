#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Aztec / geometric border pattern
void main() {
    vec2 p = uv * 6.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Background
    vec3 col = vec3(0.12, 0.08, 0.05);
    
    // Terracotta base
    float tile = step(0.03, fp.x) * step(fp.x, 0.97) * step(0.03, fp.y) * step(fp.y, 0.97);
    vec3 terracotta = vec3(0.75, 0.45, 0.25);
    col = mix(col, terracotta, tile);
    
    // Step-fret pattern (greca)
    float h = hash(id);
    float pattern = 0.0;
    
    // Horizontal step frets
    float margin = 0.15;
    float inner = 1.0 - margin;
    
    // Top border
    float top_band = step(inner, fp.y) * step(fp.y, 1.0);
    float top_step = step(margin + 0.25, mod(fp.x + h * 0.5, 0.5));
    pattern += top_band * top_step;
    
    // Bottom border
    float bot_band = step(0.0, fp.y) * step(fp.y, margin);
    float bot_step = step(mod(fp.x + h * 0.5, 0.5), margin + 0.25);
    pattern += bot_band * bot_step;
    
    // Left border
    float left_band = step(0.0, fp.x) * step(fp.x, margin);
    float left_step = step(margin + 0.25, mod(fp.y + h * 0.3, 0.5));
    pattern += left_band * left_step;
    
    // Right border
    float right_band = step(inner, fp.x) * step(fp.x, 1.0);
    float right_step = step(mod(fp.y + h * 0.3, 0.5), margin + 0.25);
    pattern += right_band * right_step;
    
    // Center diamond motif
    float cx = abs(fp.x - 0.5);
    float cy = abs(fp.y - 0.5);
    float diamond = smoothstep(0.22, 0.2, cx + cy) * (1.0 - smoothstep(0.15, 0.17, cx + cy));
    
    // Inner diamond dot
    float dot_d = length(fp - 0.5);
    float dot = smoothstep(0.05, 0.04, dot_d);
    
    vec3 teal = vec3(0.1, 0.5, 0.45);
    vec3 cream = vec3(0.9, 0.85, 0.7);
    vec3 rust = vec3(0.8, 0.35, 0.15);
    
    col = mix(col, teal, min(pattern, 1.0) * tile);
    col = mix(col, cream, diamond * tile);
    col = mix(col, rust, dot * tile);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

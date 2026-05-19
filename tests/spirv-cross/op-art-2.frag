#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test op-art with concentric distorted squares + moire interference
void main() {
    vec2 p = uv - 0.5;
    
    // Rotate slightly for visual interest
    float rot = 0.15;
    vec2 rp = vec2(p.x * cos(rot) - p.y * sin(rot), p.x * sin(rot) + p.y * cos(rot));
    
    // Concentric distorted squares
    float d1 = max(abs(rp.x), abs(rp.y));
    float rings1 = sin(d1 * 40.0) * 0.5 + 0.5;
    
    // Second set with different rotation
    float rot2 = -0.1;
    vec2 rp2 = vec2(p.x * cos(rot2) - p.y * sin(rot2), p.x * sin(rot2) + p.y * cos(rot2));
    float d2 = max(abs(rp2.x), abs(rp2.y));
    float rings2 = sin(d2 * 40.0 + 1.0) * 0.5 + 0.5;
    
    // Moire interference
    float moire = rings1 * rings2;
    
    // High contrast black/white
    float bw = smoothstep(0.3, 0.35, moire);
    
    // Vignette
    float vig = 1.0 - dot(p, p) * 2.0;
    bw *= vig;
    
    vec3 col = vec3(bw);
    
    // Subtle color tint
    col *= vec3(0.95, 0.95, 1.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

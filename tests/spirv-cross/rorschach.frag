#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Rorschach inkblot pattern (bilateral symmetry)
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    // Mirror horizontally for bilateral symmetry
    vec2 p = vec2(abs(uv.x - 0.5), uv.y);
    
    // Multiple overlapping blobs create inkblot shapes
    float blot = 0.0;
    
    // Central vertical blob
    float d1 = length((p - vec2(0.0, 0.5)) * vec2(1.5, 1.0));
    blot += smoothstep(0.25, 0.22, d1);
    
    // Wing-like extensions
    float d2 = length((p - vec2(0.15, 0.4)) * vec2(0.8, 1.2));
    blot += smoothstep(0.15, 0.12, d2) * 0.8;
    
    float d3 = length((p - vec2(0.2, 0.55)) * vec2(1.0, 0.8));
    blot += smoothstep(0.12, 0.09, d3) * 0.7;
    
    // Bottom tendrils
    float d4 = length((p - vec2(0.05, 0.25)) * vec2(0.6, 1.5));
    blot += smoothstep(0.1, 0.07, d4) * 0.6;
    
    float d5 = length((p - vec2(0.18, 0.3)) * vec2(1.0, 1.0));
    blot += smoothstep(0.08, 0.05, d5) * 0.5;
    
    // Top crown
    float d6 = length((p - vec2(0.0, 0.7)) * vec2(2.0, 0.8));
    blot += smoothstep(0.12, 0.09, d6) * 0.6;
    
    // Threshold for ink/not-ink
    float ink = smoothstep(0.5, 0.6, blot);
    
    // Ink texture
    float tex = hash(floor(p * 80.0)) * 0.1;
    ink *= 0.9 + tex;
    
    // Paper color with slight texture
    vec3 paper = vec3(0.92, 0.9, 0.85) + hash(floor(uv * 200.0)) * 0.03;
    vec3 ink_col = vec3(0.05, 0.03, 0.02);
    
    vec3 col = mix(paper, ink_col, ink);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

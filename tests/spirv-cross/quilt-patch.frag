#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test quilt patchwork pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec2 p = uv * 8.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h1 = hash(id);
    float h2 = hash(id + 100.0);
    
    // Different patch patterns per cell
    vec3 patch_col;
    float design = 0.0;
    
    float t = h1;
    if (t < 0.25) {
        // Diagonal stripes
        float stripe = step(0.5, fract((fp.x + fp.y) * 4.0));
        patch_col = mix(vec3(0.8, 0.2, 0.2), vec3(0.2, 0.2, 0.8), stripe);
    } else if (t < 0.5) {
        // Concentric square
        float ring = abs(fp.x - 0.5) + abs(fp.y - 0.5);
        float fill = smoothstep(0.35, 0.33, ring) * (1.0 - smoothstep(0.25, 0.23, ring));
        patch_col = mix(vec3(0.9, 0.8, 0.3), vec3(0.2, 0.7, 0.3), fill);
    } else if (t < 0.75) {
        // Half-square triangle
        float tri = step(fp.x, fp.y);
        patch_col = mix(vec3(0.6, 0.3, 0.5), vec3(0.3, 0.5, 0.6), tri);
    } else {
        // Polka dots
        float d1 = length(fp - vec2(0.25, 0.25));
        float d2 = length(fp - vec2(0.75, 0.75));
        float dot = smoothstep(0.12, 0.1, min(d1, d2));
        patch_col = mix(vec3(0.4, 0.7, 0.4), vec3(0.1, 0.2, 0.6), dot);
    }
    
    // Sewing lines between patches
    float seam_x = smoothstep(0.03, 0.01, fp.x) + smoothstep(0.97, 0.99, fp.x);
    float seam_y = smoothstep(0.03, 0.01, fp.y) + smoothstep(0.97, 0.99, fp.y);
    float seam = min(1.0, seam_x + seam_y);
    
    vec3 col = mix(patch_col, vec3(0.6, 0.55, 0.5), seam);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test butterfly wing scale pattern
void main() {
    vec2 p = uv * 16.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Overlapping scales (shingle pattern)
    float row = id.y;
    float offset = mod(row, 2.0) * 0.5;
    fp.x = fract(fp.x + offset);
    
    // Scale shape: rounded rectangle
    float sx = smoothstep(0.0, 0.15, fp.x) * smoothstep(1.0, 0.85, fp.x);
    float sy = smoothstep(0.0, 0.1, fp.y) * smoothstep(0.7, 0.55, fp.y);
    float scale_shape = sx * sy;
    
    // Color: iridescent blue-black morpho butterfly
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    float iri = sin(p.x * 0.3 + p.y * 0.2) * 0.5 + 0.5;
    
    vec3 blue = vec3(0.1, 0.4, 0.9) * (0.7 + iri * 0.3);
    vec3 dark = vec3(0.03, 0.03, 0.05);
    vec3 col = mix(dark, blue, scale_shape * (0.5 + h * 0.5));
    
    // Wing veins
    float vein = smoothstep(0.015, 0.0, abs(fract(uv.x * 4.0) - 0.5) - 0.485);
    float vein2 = smoothstep(0.015, 0.0, abs(fract(uv.y * 3.0) - 0.5) - 0.485);
    col = mix(col, vec3(0.05), max(vein, vein2) * 0.7);
    
    // Eye spot
    float eye_d = length(uv - vec2(0.6, 0.5));
    float eye_ring = smoothstep(0.1, 0.09, eye_d) * (1.0 - smoothstep(0.07, 0.06, eye_d));
    float eye_center = smoothstep(0.04, 0.03, eye_d);
    col = mix(col, vec3(0.9, 0.7, 0.1), eye_ring);
    col = mix(col, vec3(0.05), eye_center);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

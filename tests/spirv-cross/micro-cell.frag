#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test microscopic cell structure
void main() {
    vec2 p = uv * 6.0;
    vec2 id = floor(p);
    vec2 fp = fract(p) - 0.5;
    
    float r = length(fp);
    
    // Cell membrane
    float membrane = smoothstep(0.45, 0.43, r) * (1.0 - smoothstep(0.38, 0.40, r));
    
    // Nucleus
    float nucleus = smoothstep(0.12, 0.10, length(fp - vec2(0.05)));
    
    // Organelles (smaller circles)
    float o1 = smoothstep(0.06, 0.04, length(fp - vec2(0.2, 0.15)));
    float o2 = smoothstep(0.05, 0.03, length(fp - vec2(-0.15, 0.1)));
    float o3 = smoothstep(0.04, 0.02, length(fp - vec2(0.1, -0.2)));
    
    // Per-cell variation
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    vec3 cyto = vec3(0.7, 0.85, 0.7) * (0.8 + h * 0.2);
    vec3 memb = vec3(0.4, 0.5, 0.3);
    vec3 nuc = vec3(0.3, 0.2, 0.5);
    vec3 org = vec3(0.6, 0.3, 0.3);
    
    vec3 col = cyto;
    col = mix(col, memb, membrane);
    col = mix(col, nuc, nucleus);
    col = mix(col, org, max(max(o1, o2), o3));
    
    fragColor = vec4(col, 1.0);
}

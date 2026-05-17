#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test 2D lattice pattern with connected nodes
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 p = uv * 6.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float min_d = 1.0;
    
    // Check distances to nearby cell centers
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 center = vec2(
                hash(id + neighbor),
                hash(id + neighbor + 100.0)
            );
            float d = length(neighbor + center - fp);
            min_d = min(min_d, d);
        }
    }
    
    // Node dots
    float node = smoothstep(0.08, 0.05, min_d);
    
    // Lines between nodes (approximated)
    float lines = smoothstep(0.03, 0.01, min_d) - node;
    
    vec3 col = vec3(0.05);
    col += node * vec3(0.9, 0.7, 0.3);
    col += lines * vec3(0.3, 0.5, 0.7);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test generating normal from gradient
float heightMap(vec2 p) {
    return sin(p.x * 3.0) * cos(p.y * 3.0) * 0.5;
}

vec3 computeNormal(vec2 p) {
    float eps = 0.01;
    float h = heightMap(p);
    float hx = heightMap(p + vec2(eps, 0.0));
    float hy = heightMap(p + vec2(0.0, eps));
    
    vec3 n = normalize(vec3((h - hx) / eps, 1.0, (h - hy) / eps));
    return n;
}

void main() {
    vec2 p = uv * 4.0 - 2.0;
    float h = heightMap(p);
    vec3 n = computeNormal(p);
    
    // Simple directional light
    vec3 light = normalize(vec3(0.5, 1.0, 0.3));
    float diff = max(dot(n, light), 0.0);
    
    vec3 col = vec3(0.3, 0.5, 0.2) * (diff * 0.8 + 0.2);
    col += vec3(0.1) * h;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

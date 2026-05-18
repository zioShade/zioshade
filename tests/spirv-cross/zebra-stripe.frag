#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test zebra stripe moire pattern
void main() {
    vec2 p = uv * 20.0;
    
    // Diagonal stripes
    float stripe1 = sin(p.x + p.y) * 0.5 + 0.5;
    float stripe2 = sin(p.x - p.y + 1.0) * 0.5 + 0.5;
    
    // Intersect to create zebra pattern
    float zebra = min(stripe1, stripe2);
    zebra = smoothstep(0.4, 0.5, zebra);
    
    vec3 col = mix(vec3(0.05), vec3(0.85, 0.8, 0.7), zebra);
    
    fragColor = vec4(col, 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Mondrian-style geometric composition
void main() {
    vec2 p = uv;
    
    // Define rectangular regions with hardcoded boundaries
    // Horizontal dividers at y=0.3, y=0.7
    // Vertical dividers at x=0.25, x=0.6, x=0.8
    float h1 = smoothstep(0.005, 0.0, abs(p.y - 0.3));
    float h2 = smoothstep(0.005, 0.0, abs(p.y - 0.7));
    float v1 = smoothstep(0.005, 0.0, abs(p.x - 0.25));
    float v2 = smoothstep(0.005, 0.0, abs(p.x - 0.6));
    float v3 = smoothstep(0.005, 0.0, abs(p.x - 0.8));
    
    float lines = min(1.0, h1 + h2 + v1 + v2 + v3);
    
    // Color each region
    vec3 col;
    // Top row
    if (p.y > 0.7) {
        if (p.x < 0.6) col = vec3(0.85, 0.15, 0.1); // Red
        else col = vec3(0.95); // White
    }
    // Middle row
    else if (p.y > 0.3) {
        if (p.x < 0.25) col = vec3(0.95); // White
        else if (p.x < 0.6) col = vec3(0.95); // White
        else col = vec3(0.2, 0.3, 0.75); // Blue
    }
    // Bottom row
    else {
        if (p.x < 0.25) col = vec3(0.95); // White
        else if (p.x < 0.8) col = vec3(0.95, 0.85, 0.1); // Yellow
        else col = vec3(0.95); // White
    }
    
    // Black lines
    col = mix(col, vec3(0.05), lines);
    
    // Outer border
    float border = step(p.x, 0.01) + step(0.99, p.x) + step(p.y, 0.01) + step(0.99, p.y);
    col = mix(col, vec3(0.05), min(border, 1.0));
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

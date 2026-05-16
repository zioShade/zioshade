#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Cross-hatch shading
void main() {
    vec2 p = uv * 20.0;
    
    float brightness = sin(uv.x * 3.14) * sin(uv.y * 3.14);
    
    // Diagonal lines in both directions
    float diag1 = sin(p.x + p.y);
    float diag2 = sin(p.x - p.y);
    
    float hatch1 = smoothstep(0.0, 0.3, diag1);
    float hatch2 = smoothstep(0.0, 0.3, diag2);
    
    float darkness = 1.0 - brightness;
    float hatching = 1.0;
    if (darkness > 0.3) hatching = min(hatching, hatch1);
    if (darkness > 0.6) hatching = min(hatching, hatch2);
    
    vec3 col = vec3(hatching * brightness);
    fragColor = vec4(col, 1.0);
}

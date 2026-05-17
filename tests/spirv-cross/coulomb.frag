#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Coulomb's law potential from multiple charges
float potential(vec2 p, vec2 charge, float q) {
    float d = length(p - charge);
    return q / (d + 0.01);
}

void main() {
    vec2 p = uv * 4.0 - 2.0;
    
    // Multiple charges
    float v = 0.0;
    v += potential(p, vec2(-1.0, 0.0), 1.0);
    v += potential(p, vec2(1.0, 0.0), 1.0);
    v += potential(p, vec2(0.0, 1.0), -1.0);
    v += potential(p, vec2(0.0, -1.0), -1.0);
    
    // Equipotential lines
    float lines = sin(v * 5.0) * 0.5 + 0.5;
    
    vec3 col = vec3(lines, lines * 0.7, 1.0 - lines * 0.5);
    col *= 0.5 + 0.5 * exp(-abs(v) * 0.3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

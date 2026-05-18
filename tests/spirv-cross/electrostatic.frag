#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test electrostatic field lines between charges
void main() {
    vec2 p = uv - 0.5;
    
    // Two point charges
    vec2 q1 = vec2(-0.2, 0.0);
    vec2 q2 = vec2(0.2, 0.0);
    
    float d1 = length(p - q1);
    float d2 = length(p - q2);
    
    // Electric potential (positive charge + negative charge)
    float potential = 1.0 / (d1 + 0.01) - 1.0 / (d2 + 0.01);
    
    // Equipotential lines
    float equi = sin(potential * 3.0) * 0.5 + 0.5;
    float equi_line = smoothstep(0.48, 0.5, equi) * (1.0 - smoothstep(0.5, 0.52, equi));
    
    // Field line direction (approximate)
    vec2 e1 = (p - q1) / (d1 * d1 + 0.01);
    vec2 e2 = (p - q2) / (d2 * d2 + 0.01);
    vec2 field = e1 - e2;
    float field_mag = length(field);
    
    // Streamline effect
    float stream = sin(atan(field.y, field.x) * 8.0) * 0.5 + 0.5;
    float stream_line = smoothstep(0.48, 0.5, stream) * (1.0 - smoothstep(0.5, 0.52, stream));
    
    // Background: field intensity heatmap
    float intensity = clamp(field_mag * 0.05, 0.0, 1.0);
    vec3 bg = mix(vec3(0.02, 0.02, 0.08), vec3(0.15, 0.1, 0.3), intensity);
    
    vec3 col = bg;
    col += equi_line * vec3(0.2, 0.5, 0.8);
    col += stream_line * vec3(0.6, 0.4, 0.2) * smoothstep(0.01, 0.1, field_mag);
    
    // Charge markers
    float mark1 = smoothstep(0.02, 0.015, d1);
    float mark2 = smoothstep(0.02, 0.015, d2);
    col += mark1 * vec3(1.0, 0.3, 0.2);
    col += mark2 * vec3(0.2, 0.3, 1.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

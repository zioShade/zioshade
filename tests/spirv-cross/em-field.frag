#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Electromagnetic field visualization
void main() {
    vec2 p = uv * 4.0 - 2.0;
    
    // Two charges
    float q1 = 1.0;
    float q2 = -1.0;
    vec2 p1 = vec2(-0.5, 0.0);
    vec2 p2 = vec2(0.5, 0.0);
    
    float d1 = length(p - p1);
    float d2 = length(p - p2);
    
    // Electric field magnitude
    float E = q1 / (d1 * d1 + 0.01) - q2 / (d2 * d2 + 0.01);
    E = abs(E);
    
    // Field direction (normalized)
    vec2 dir = q1 * (p - p1) / (d1 * d1 * d1 + 0.001) - q2 * (p - p2) / (d2 * d2 * d2 + 0.001);
    float angle = atan(dir.y, dir.x);
    
    // Color by field direction
    vec3 col = vec3(
        sin(angle) * 0.5 + 0.5,
        sin(angle + 2.094) * 0.5 + 0.5,
        sin(angle + 4.189) * 0.5 + 0.5
    );
    
    // Modulate by field strength
    float strength = log(E + 1.0) * 0.3;
    col *= clamp(strength, 0.0, 1.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

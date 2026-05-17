#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test parabolic reflector pattern
void main() {
    vec2 p = uv * 4.0 - 2.0;
    
    // Parabola: y = x^2
    float parabola = p.x * p.x;
    
    // Distance to parabola curve
    float d = abs(p.y - parabola);
    float curve = smoothstep(0.05, 0.02, d);
    
    // Reflected rays
    float ray = 0.0;
    for (int i = 0; i < 5; i++) {
        float source_y = float(i) * 0.5 + 0.5;
        float xi = sqrt(source_y);
        
        // Focus at (0, 0.25)
        vec2 focus = vec2(0.0, 0.25);
        vec2 hit = vec2(xi, source_y);
        vec2 refl_dir = normalize(focus - hit);
        
        // Simplified ray march
        float t = (p.x - hit.x) / (refl_dir.x + 0.001);
        float ry = hit.y + t * refl_dir.y;
        
        if (t > 0.0) {
            ray += smoothstep(0.03, 0.0, abs(p.y - ry));
        }
    }
    
    vec3 col = curve * vec3(0.8, 0.6, 0.2) + ray * vec3(0.3, 0.5, 0.8);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

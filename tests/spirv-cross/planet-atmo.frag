#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Planet with atmosphere
void main() {
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    
    // Planet surface
    float surface = 1.0 - smoothstep(0.38, 0.4, r);
    
    // Surface detail
    float detail = sin(atan(p.y, p.x) * 8.0) * sin(r * 20.0);
    detail = detail * 0.5 + 0.5;
    
    // Atmosphere glow
    float atmosphere = exp(-abs(r - 0.4) * 8.0);
    atmosphere *= step(0.35, r);
    
    vec3 planet_col = mix(vec3(0.2, 0.4, 0.2), vec3(0.6, 0.5, 0.3), detail) * surface;
    vec3 atmo_col = vec3(0.3, 0.5, 1.0) * atmosphere * 0.6;
    vec3 bg_col = vec3(0.02, 0.02, 0.05);
    
    vec3 col = bg_col + planet_col + atmo_col;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test jellyfish with bioluminescence
void main() {
    vec2 p = uv - vec2(0.5, 0.45);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Deep ocean background
    vec3 col = mix(vec3(0.0, 0.02, 0.08), vec3(0.0, 0.01, 0.04), uv.y);
    
    // Bell (dome shape)
    float bell_r = 0.18;
    float bell_top = smoothstep(0.0, 0.05, p.y);
    float bell = smoothstep(bell_r, bell_r - 0.008, r) * bell_top;
    
    // Bioluminescent purple-blue color
    vec3 jelly_col = vec3(0.5, 0.3, 0.9);
    vec3 jelly_edge = vec3(0.3, 0.2, 0.7);
    float edge = smoothstep(0.05, bell_r, r);
    vec3 bell_col = mix(jelly_col, jelly_edge, edge);
    col = mix(col, bell_col * 0.6, bell);
    
    // Bell pattern: radial lines
    float lines = smoothstep(0.06, 0.03, abs(sin(a * 12.0))) * bell * 0.3;
    col += lines * vec3(0.6, 0.4, 1.0);
    
    // Inner glow
    float inner_glow = exp(-r * r * 30.0) * 0.3;
    col += inner_glow * vec3(0.5, 0.3, 0.9);
    
    // Tentacles (wavy lines hanging down)
    float tentacles = 0.0;
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float tx = 0.5 + sin(fi * 1.7) * 0.12;
        float wave = sin(uv.y * 15.0 + fi * 2.0) * 0.015;
        float tent = smoothstep(0.004, 0.001, abs(uv.x - (tx + wave)));
        tent *= step(0.25, uv.y) * smoothstep(0.25, 0.35, uv.y);
        tent *= smoothstep(0.85, 0.5, uv.y);
        tentacles += tent;
    }
    col += tentacles * vec3(0.4, 0.25, 0.8) * 0.5;
    
    // Bioluminescent particles
    float particles = 0.0;
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        float px = 0.3 + fract(sin(fi * 7.3) * 100.0) * 0.4;
        float py = 0.2 + fract(cos(fi * 11.1) * 100.0) * 0.6;
        float pd = length(uv - vec2(px, py));
        particles += exp(-pd * 80.0) * 0.15;
    }
    col += particles * vec3(0.4, 0.6, 1.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

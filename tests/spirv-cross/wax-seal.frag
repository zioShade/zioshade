#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test wax seal pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Seal disc
    float seal = smoothstep(0.38, 0.36, r);
    
    // Embossed star pattern
    float star = 0.0;
    float arms = 8.0;
    float star_a = a;
    float star_r = cos(star_a * arms) * 0.5 + 0.5;
    float inner = smoothstep(0.18, 0.16, r) * star_r;
    star = inner;
    
    // Concentric rings (embossing)
    float rings = sin(r * 30.0) * 0.5 + 0.5;
    float ring_emboss = smoothstep(0.48, 0.35, rings) * seal * 0.3;
    
    // Letter in center
    float letter_x = smoothstep(0.03, 0.02, abs(p.x));
    float letter_y = smoothstep(0.08, 0.06, abs(p.y));
    float letter_h = smoothstep(0.02, 0.015, abs(p.y - 0.0)) * step(abs(p.x), 0.015);
    float letter = max(max(letter_x, letter_y) * step(r, 0.1), letter_h * step(r, 0.12));
    
    // Wax colors
    vec3 wax_dark = vec3(0.6, 0.1, 0.08);
    vec3 wax_light = vec3(0.85, 0.25, 0.12);
    vec3 wax_base = mix(wax_dark, wax_light, 0.5 + 0.2 * sin(a * 3.0));
    
    // Embossing highlight
    float highlight = exp(-dot(p - vec2(-0.08, -0.08), p - vec2(-0.08, -0.08)) * 20.0) * seal * 0.3;
    
    vec3 col = vec3(0.95, 0.92, 0.85); // paper
    col = mix(col, wax_base, seal);
    col = mix(col, wax_light * 0.8, star);
    col += ring_emboss;
    col += highlight;
    col = mix(col, wax_light * 1.2, letter * seal);
    
    // Edge drip
    float drip = smoothstep(0.38, 0.4, r) * smoothstep(0.42, 0.4, r) * (0.5 + 0.5 * sin(a * 5.0));
    col = mix(col, wax_dark, drip);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

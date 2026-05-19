#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test diffraction grating / spectral dispersion
void main() {
    // White light source from top
    vec3 col = vec3(0.01);
    
    // Light source
    float src_d = length(uv - vec2(0.5, 0.9));
    float source = exp(-src_d * 15.0);
    col += source * vec3(1.0, 0.98, 0.95);
    
    // Grating (horizontal slit)
    float slit_y = 0.7;
    float slit = smoothstep(0.003, 0.001, abs(uv.y - slit_y)) * step(0.35, uv.x) * step(uv.x, 0.65);
    col += slit * vec3(0.8);
    
    // Diffraction orders (spectral lines spreading below grating)
    float below = step(uv.y, slit_y - 0.01);
    float dy = slit_y - uv.y;
    float dx = uv.x - 0.5;
    
    // First order: spread increases with distance, different angles per wavelength
    float order1 = exp(-dx * dx * 200.0 / (dy + 0.01)) * below;
    
    // Rainbow colors spread horizontally
    float spread = dx / (dy + 0.001) * 3.0;
    
    vec3 red = vec3(0.9, 0.1, 0.05) * smoothstep(0.02, 0.01, abs(spread - 0.8));
    vec3 orange = vec3(0.95, 0.5, 0.05) * smoothstep(0.02, 0.01, abs(spread - 0.6));
    vec3 yellow = vec3(0.95, 0.9, 0.1) * smoothstep(0.02, 0.01, abs(spread - 0.4));
    vec3 green = vec3(0.1, 0.85, 0.15) * smoothstep(0.02, 0.01, abs(spread - 0.2));
    vec3 blue = vec3(0.1, 0.2, 0.9) * smoothstep(0.02, 0.01, abs(spread + 0.0));
    vec3 indigo = vec3(0.3, 0.05, 0.7) * smoothstep(0.02, 0.01, abs(spread + 0.2));
    vec3 violet = vec3(0.5, 0.0, 0.5) * smoothstep(0.02, 0.01, abs(spread + 0.4));
    
    // Mirror on negative side
    float spread_neg = -spread;
    vec3 red2 = vec3(0.9, 0.1, 0.05) * smoothstep(0.02, 0.01, abs(spread_neg - 0.8));
    vec3 orange2 = vec3(0.95, 0.5, 0.05) * smoothstep(0.02, 0.01, abs(spread_neg - 0.6));
    vec3 yellow2 = vec3(0.95, 0.9, 0.1) * smoothstep(0.02, 0.01, abs(spread_neg - 0.4));
    vec3 green2 = vec3(0.1, 0.85, 0.15) * smoothstep(0.02, 0.01, abs(spread_neg - 0.2));
    vec3 blue2 = vec3(0.1, 0.2, 0.9) * smoothstep(0.02, 0.01, abs(spread_neg + 0.0));
    vec3 indigo2 = vec3(0.3, 0.05, 0.7) * smoothstep(0.02, 0.01, abs(spread_neg + 0.2));
    vec3 violet2 = vec3(0.5, 0.0, 0.5) * smoothstep(0.02, 0.01, abs(spread_neg + 0.4));
    
    float intensity = order1 * 2.0;
    col += (red + orange + yellow + green + blue + indigo + violet +
            red2 + orange2 + yellow2 + green2 + blue2 + indigo2 + violet2) * intensity;
    
    // Zeroth order (center, white)
    float zero_order = exp(-dx * dx * 500.0 / (dy + 0.01)) * below * 0.3;
    col += zero_order * vec3(0.8);
    
    // Second order (wider spread, dimmer)
    float spread2 = dx / (dy + 0.001) * 1.5;
    float order2 = exp(-dx * dx * 50.0 / (dy + 0.01)) * below * 0.3;
    vec3 spectrum2 = vec3(0.9, 0.1, 0.05) * smoothstep(0.02, 0.01, abs(spread2 - 1.6));
    spectrum2 += vec3(0.1, 0.2, 0.9) * smoothstep(0.02, 0.01, abs(spread2 + 1.6));
    col += spectrum2 * order2;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

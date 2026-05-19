#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test solar flare / corona pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Deep space background
    vec3 col = vec3(0.01, 0.0, 0.02);
    
    // Stars
    float star = step(0.997, fract(sin(dot(floor(uv * 300.0), vec2(12.9, 78.2))) * 43758.5));
    col += star * vec3(0.5, 0.55, 0.7);
    
    // Sun body
    float sun = smoothstep(0.12, 0.115, r);
    vec3 sun_col = vec3(1.0, 0.95, 0.7);
    col = mix(col, sun_col, sun);
    
    // Corona glow (multiple layers)
    float corona1 = exp(-r * 6.0) * 0.5;
    float corona2 = exp(-r * 3.0) * 0.2;
    col += (corona1 + corona2) * vec3(1.0, 0.7, 0.3) * (1.0 - sun);
    
    // Solar prominences (arching loops)
    float prominence = 0.0;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float pa = fi * 1.0472 + 0.5;
        vec2 dir = vec2(cos(pa), sin(pa));
        float proj = dot(p, dir);
        float perp = abs(dot(p, vec2(-dir.y, dir.x)));
        
        // Arch shape
        float arch = smoothstep(0.25, 0.2, proj) * step(0.0, proj);
        float width = 0.005 + proj * 0.02;
        arch *= smoothstep(width, width - 0.003, perp);
        prominence += arch;
    }
    col += min(prominence, 1.0) * vec3(0.9, 0.3, 0.1) * (1.0 - sun);
    
    // Solar flares (radial spikes)
    float flare = 0.0;
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        float fa = fi * 0.5236;
        float diff = abs(a - fa);
        diff = min(diff, 6.2832 - diff);
        float spike = exp(-diff * 15.0) * exp(-r * 4.0);
        flare += spike;
    }
    col += flare * vec3(1.0, 0.8, 0.4) * 0.3 * (1.0 - sun);
    
    // Surface granulation
    float gran = sin(a * 20.0 + r * 30.0) * 0.03;
    col += gran * sun;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

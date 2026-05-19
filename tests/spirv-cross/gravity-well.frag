#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test gravity well / spacetime curvature
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Background: starfield
    float star = step(0.997, fract(sin(dot(floor(uv * 200.0), vec2(12.9, 78.2))) * 43758.5));
    vec3 col = vec3(0.01, 0.01, 0.03) + star * vec3(0.5, 0.55, 0.7);
    
    // Grid lines distorted by gravity
    float grid = 0.0;
    for (int i = -5; i <= 5; i++) {
        // Horizontal lines, curved by gravity
        float base_y = float(i) * 0.1;
        vec2 gp = uv - vec2(0.5, 0.5 + base_y);
        float gr = length(gp);
        float deflection = 0.02 / (gr + 0.05);
        float distorted_y = gp.y - deflection * sign(gp.y);
        float hline = smoothstep(0.003, 0.001, abs(distorted_y));
        float in_range = step(abs(base_y), 0.5);
        grid += hline * in_range;
        
        // Vertical lines
        float base_x = float(i) * 0.1;
        vec2 gvp = uv - vec2(0.5 + base_x, 0.5);
        float gvr = length(gvp);
        float vdeflection = 0.02 / (gvr + 0.05);
        float distorted_x = gvp.x - vdeflection * sign(gvp.x);
        float vline = smoothstep(0.003, 0.001, abs(distorted_x));
        grid += vline * in_range;
    }
    grid = min(grid, 1.0);
    
    // Central mass (black hole)
    float hole = smoothstep(0.04, 0.03, r);
    float ring = smoothstep(0.06, 0.05, r) * (1.0 - smoothstep(0.04, 0.035, r));
    
    // Accretion disk glow
    float disk = exp(-r * 6.0) * 0.3;
    
    col += grid * vec3(0.15, 0.25, 0.5) * (1.0 - hole);
    col = mix(col, vec3(0.0), hole);
    col += ring * vec3(0.9, 0.6, 0.2);
    col += disk * vec3(1.0, 0.5, 0.15);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 450
layout(location = 0) out vec4 FragColor;

// Crop circle with spoke accumulation in loop
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float r = length(uv);
    float angle = atan(uv.y, uv.x);
    
    // Concentric rings
    float rings = sin(r * 20.0) * 0.5 + 0.5;
    
    // Spoke accumulation
    float spokes = 0.0;
    for (int i = 0; i < 8; i++) {
        float spoke_angle = float(i) * 3.14159 / 4.0;
        float d = abs(angle - spoke_angle);
        d = min(d, 6.28318 - d);
        spokes += smoothstep(0.1, 0.0, d) * (1.0 - r);
    }
    spokes = min(spokes, 1.0);
    
    float field = rings * 0.5 + spokes * 0.5;
    vec3 wheat = vec3(0.85, 0.75, 0.35);
    vec3 dirt = vec3(0.35, 0.25, 0.15);
    vec3 col = mix(dirt, wheat, field * step(r, 1.0));
    
    FragColor = vec4(col, 1.0);
}

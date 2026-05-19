#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test volcano eruption pattern
void main() {
    vec2 p = uv - vec2(0.5, 0.3);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Sky gradient
    vec3 sky_low = vec3(0.6, 0.3, 0.15);
    vec3 sky_high = vec3(0.1, 0.05, 0.15);
    vec3 col = mix(sky_low, sky_high, uv.y);
    
    // Stars in upper sky
    float star = step(0.998, fract(sin(dot(floor(uv * 300.0), vec2(12.9, 78.2))) * 43758.5));
    col += star * vec3(0.7) * smoothstep(0.5, 0.8, uv.y);
    
    // Mountain / volcano shape
    float mountain = smoothstep(0.0, 0.08, uv.y - 0.3 * (1.0 - abs(uv.x - 0.5) * 1.5));
    // Crater opening at top
    float crater = smoothstep(0.02, 0.0, abs(uv.y - 0.3 * (1.0 - abs(uv.x - 0.5) * 1.5)));
    crater *= step(0.43, uv.x) * step(uv.x, 0.57);
    
    vec3 rock = vec3(0.25, 0.2, 0.15);
    col = mix(col, rock, mountain);
    
    // Lava glow from crater
    float glow = exp(-length(uv - vec2(0.5, 0.35)) * 5.0) * 0.8;
    col += glow * vec3(1.0, 0.5, 0.1);
    col += crater * vec3(1.0, 0.6, 0.1);
    
    // Eruption particles / lava spray
    float spray = 0.0;
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        float px = 0.5 + sin(fi * 2.7) * 0.12;
        float py = 0.38 + fi * 0.045;
        float size = 0.012 - fi * 0.001;
        float d = length(uv - vec2(px, py));
        spray += smoothstep(size, size - 0.003, d);
    }
    col += spray * vec3(1.0, 0.4, 0.05);
    
    // Lava flow down sides
    float flow_l = smoothstep(0.01, 0.005, abs(uv.x - (0.42 - (uv.y - 0.25) * 0.3)));
    float flow_r = smoothstep(0.01, 0.005, abs(uv.x - (0.58 + (uv.y - 0.25) * 0.3)));
    float flow_mask = step(0.05, uv.y) * smoothstep(0.32, 0.25, uv.y);
    col += (flow_l + flow_r) * flow_mask * vec3(0.9, 0.3, 0.05);
    
    // Ground / base
    float ground = step(uv.y, 0.08);
    col = mix(col, vec3(0.15, 0.1, 0.05), ground);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

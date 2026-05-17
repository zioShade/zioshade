#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test chain-link fence pattern
void main() {
    vec2 p = uv * 10.0;
    
    // Diagonal lines in both directions
    float d1 = abs(fract((p.x + p.y) * 0.5) - 0.5);
    float d2 = abs(fract((p.x - p.y) * 0.5) - 0.5);
    
    float line1 = smoothstep(0.05, 0.03, d1);
    float line2 = smoothstep(0.05, 0.03, d2);
    
    // Over-under pattern
    vec2 id = floor(p);
    float over = step(0.5, fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5));
    
    float chain = max(line1, line2);
    
    // Shadow for depth
    float shadow = max(
        smoothstep(0.06, 0.04, d1) * over,
        smoothstep(0.06, 0.04, d2) * (1.0 - over)
    );
    
    vec3 bg = vec3(0.3, 0.5, 0.7);
    vec3 wire = vec3(0.5, 0.5, 0.5);
    vec3 shade = vec3(0.3, 0.3, 0.3);
    
    vec3 col = bg;
    col = mix(col, shade, shadow);
    col = mix(col, wire, chain);
    
    fragColor = vec4(col, 1.0);
}

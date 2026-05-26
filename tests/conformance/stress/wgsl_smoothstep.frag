// Test: smoothstep, mix, step chain
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float edge1 = smoothstep(0.2, 0.8, uv.x);
    float edge2 = smoothstep(0.3, 0.7, uv.y);
    float stepped = step(0.5, uv.x);
    float mixed = mix(edge1, edge2, stepped);
    float clamped = clamp(mixed * 2.0, 0.0, 1.0);
    
    vec3 color = mix(vec3(0.2, 0.4, 0.8), vec3(0.8, 0.3, 0.1), clamped);
    
    fragColor = vec4(color, 1.0);
}

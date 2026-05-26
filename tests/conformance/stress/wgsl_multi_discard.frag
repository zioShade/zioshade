// Test: multiple discard conditions
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    // Circular mask
    float dist = length(uv - 0.5);
    if (dist > 0.5) discard;
    
    // Grid mask
    vec2 grid = fract(uv * 10.0);
    if (grid.x < 0.1 || grid.y < 0.1) discard;
    
    float ring = abs(dist - 0.3);
    if (ring < 0.02) discard;
    
    vec3 color = vec3(uv, 0.5);
    fragColor = vec4(color, 1.0);
}

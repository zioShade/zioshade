// Test: Infinite grid shader
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    // Scale and center
    vec2 p = uv * 20.0 - 10.0;
    
    // Grid lines
    vec2 grid = abs(fract(p) - 0.5);
    float line = min(grid.x, grid.y);
    float gridMask = 1.0 - smoothstep(0.0, 0.05, line);
    
    // Major grid lines
    vec2 majorGrid = abs(fract(p * 0.2) - 0.5);
    float majorLine = min(majorGrid.x, majorGrid.y);
    float majorMask = 1.0 - smoothstep(0.0, 0.03, majorLine);
    
    // Fade with distance
    float dist = length(p);
    float fade = 1.0 / (1.0 + dist * 0.1);
    
    vec3 color = vec3(0.1);
    color += vec3(0.2) * gridMask * fade;
    color += vec3(0.3) * majorMask * fade;
    
    fragColor = vec4(color, 1.0);
}

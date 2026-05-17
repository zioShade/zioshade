#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test marble maze pattern
void main() {
    vec2 p = uv * 8.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    // Wall segments based on hash
    float wall = 0.0;
    
    // Top wall
    if (h > 0.5) wall = max(wall, 1.0 - smoothstep(0.9, 0.95, fp.y));
    // Bottom wall
    if (h > 0.3 && h < 0.7) wall = max(wall, smoothstep(0.05, 0.1, fp.y));
    // Left wall
    if (h < 0.4 || h > 0.8) wall = max(wall, 1.0 - smoothstep(0.85, 0.9, fp.x));
    // Right wall
    if (h > 0.6) wall = max(wall, smoothstep(0.05, 0.1, fp.x));
    
    // Marble (ball)
    vec2 ball_pos = vec2(fract(sin(uv.x * 7.0) * 43758.5), fract(sin(uv.y * 5.0) * 43758.5));
    float ball = smoothstep(0.02, 0.01, length(uv * 8.0 - ball_pos * 8.0));
    
    vec3 floor_col = vec3(0.9, 0.85, 0.75);
    vec3 wall_col = vec3(0.4, 0.35, 0.3);
    vec3 ball_col = vec3(0.8, 0.2, 0.1);
    
    vec3 col = mix(floor_col, wall_col, wall);
    col = mix(col, ball_col, ball);
    
    fragColor = vec4(col, 1.0);
}

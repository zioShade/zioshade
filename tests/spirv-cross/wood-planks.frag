#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test plank/wood floor pattern
void main() {
    vec2 p = uv * 8.0;
    float plank_id = floor(p.x);
    vec2 local = fract(p);
    
    // Offset rows
    float row_offset = mod(floor(p.y * 0.5) * 3.7, 8.0);
    
    // Plank gaps
    float gap_x = step(0.02, local.x) * (1.0 - step(0.98, local.x));
    float gap_y = step(0.01, local.y) * (1.0 - step(0.99, local.y));
    float plank = gap_x * gap_y;
    
    // Wood grain within plank
    float grain = sin(local.y * 40.0 + sin(local.x * 3.0 + plank_id) * 2.0) * 0.5 + 0.5;
    
    float variation = fract(sin(plank_id * 17.0 + row_offset) * 43758.5);
    vec3 wood = mix(vec3(0.55, 0.35, 0.15), vec3(0.7, 0.5, 0.25), grain * variation);
    
    vec3 col = mix(vec3(0.15), wood, plank);
    fragColor = vec4(col, 1.0);
}

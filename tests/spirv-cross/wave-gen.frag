#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test triangular wave generation
void main() {
    float tri_x = abs(fract(uv.x * 4.0) * 2.0 - 1.0);
    float tri_y = abs(fract(uv.y * 3.0) * 2.0 - 1.0);
    
    // Sawtooth
    float saw_x = fract(uv.x * 5.0);
    float saw_y = fract(uv.y * 4.0);
    
    // Mix waves
    float wave = tri_x * saw_y + tri_y * saw_x;
    wave *= 0.5;
    
    vec3 col = vec3(wave, tri_x * 0.5, tri_y * 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

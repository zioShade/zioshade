#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Musical waveform visualization
void main() {
    float x = uv.x;
    float y = uv.y;
    
    // Superposition of harmonics
    float wave = 0.0;
    wave += sin(x * 6.28 * 2.0) * 0.3;
    wave += sin(x * 6.28 * 3.0 + 0.5) * 0.2;
    wave += sin(x * 6.28 * 5.0 + 1.0) * 0.15;
    wave += sin(x * 6.28 * 7.0 + 1.5) * 0.1;
    wave += sin(x * 6.28 * 11.0) * 0.05;
    wave = wave * 0.5 + 0.5;
    
    float thickness = 0.02;
    float line = smoothstep(thickness, 0.0, abs(y - wave));
    
    // Fill below wave
    float fill = step(y, wave);
    
    vec3 col = vec3(0.0);
    col += vec3(0.1, 0.2, 0.4) * fill;
    col += vec3(0.4, 0.7, 1.0) * line;
    
    fragColor = vec4(col, 1.0);
}

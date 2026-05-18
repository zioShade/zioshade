#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test spectrogram / waterfall display
void main() {
    float x = uv.x * 6.28 * 8.0;
    float y = uv.y;
    
    // Frequency content varies with y position (time axis)
    float freq1 = sin(x * (1.0 + y * 3.0)) * 0.5;
    float freq2 = sin(x * (3.0 - y * 2.0) + 1.5) * 0.3;
    float freq3 = sin(x * 5.0 + y * 4.0) * 0.2;
    
    float signal = freq1 + freq2 + freq3;
    float magnitude = abs(signal);
    magnitude = pow(magnitude, 0.7);
    
    // Heat map coloring
    vec3 col;
    if (magnitude < 0.2) col = vec3(0.0, 0.0, magnitude * 2.0);
    else if (magnitude < 0.5) col = vec3(0.0, (magnitude - 0.2) * 3.3, 0.4);
    else if (magnitude < 0.8) col = vec3((magnitude - 0.5) * 3.3, 1.0, 0.4 * (1.0 - (magnitude - 0.5) * 2.0));
    else col = vec3(1.0, 1.0 - (magnitude - 0.8) * 5.0, 0.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

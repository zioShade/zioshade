#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Fractal flames style (iterative function system)
void main() {
    vec2 p = (uv - 0.5) * 3.0;
    float sum = 0.0;
    
    for (int i = 0; i < 20; i++) {
        // Sierpinski-like transform
        float r = fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
        
        if (r < 0.33) {
            p = p * 0.5;
        } else if (r < 0.66) {
            p = p * 0.5 + vec2(0.5, 0.0);
        } else {
            p = p * 0.5 + vec2(0.0, 0.5);
        }
        
        // Accumulate
        float d = length(uv - (p / 3.0 + 0.5));
        sum += exp(-d * 50.0) * 0.1;
    }
    
    vec3 col = vec3(sum * 0.5, sum * 0.8, sum);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

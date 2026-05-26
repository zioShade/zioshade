// Test: array initialization and iteration patterns
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    // Const array
    float weights[5];
    weights[0] = 0.1;
    weights[1] = 0.2;
    weights[2] = 0.4;
    weights[3] = 0.2;
    weights[4] = 0.1;
    
    // Compute weighted sum
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i) / 5.0;
        float sample_val = sin(uv.x * 3.14159 + fi * 6.28318);
        sum += weights[i] * sample_val;
    }
    
    // Find max index
    int maxIdx = 0;
    float maxVal = weights[0];
    for (int i = 1; i < 5; i++) {
        if (weights[i] > maxVal) {
            maxVal = weights[i];
            maxIdx = i;
        }
    }
    
    fragColor = vec4(sum * 0.5 + 0.5, float(maxIdx) / 5.0, maxVal, 1.0);
}

// Test: conditional stores with nested if-else and loop breaks
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float accum = 0.0;
    float maxVal = 0.0;
    int bestIdx = 0;
    
    for (int i = 0; i < 16; i++) {
        float fi = float(i) / 16.0;
        float v = sin(fi * 6.28318) * 0.5 + 0.5;
        
        if (v > maxVal) {
            maxVal = v;
            bestIdx = i;
        }
        
        accum += v * 0.01;
        
        if (accum > 0.5) {
            break;
        }
    }
    
    if (bestIdx > 8) {
        accum *= 0.5;
    } else if (bestIdx > 4) {
        accum *= 0.75;
    } else {
        accum *= 1.5;
    }
    
    fragColor = vec4(accum, maxVal, float(bestIdx) / 16.0, 1.0);
}

// Test: complex loop with multiple break conditions
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float result = 0.0;
    int iterations = 0;
    
    for (int i = 0; i < 100; i++) {
        float fi = float(i);
        float x = sin(fi * 0.1 + uv.x * 6.28) * 0.5 + 0.5;
        float y = cos(fi * 0.07 + uv.y * 6.28) * 0.5 + 0.5;
        
        result += x * y * 0.01;
        iterations = i;
        
        // Break condition 1: result exceeds threshold
        if (result > 0.8) break;
        
        // Break condition 2: x and y both small
        if (x < 0.1 && y < 0.1) break;
        
        // Break condition 3: iteration limit based on position
        if (i > 50 && uv.x > 0.5) break;
    }
    
    fragColor = vec4(result, float(iterations) / 100.0, 0.0, 1.0);
}

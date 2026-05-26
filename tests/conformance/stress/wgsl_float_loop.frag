// Test: complex loop with floating point counter
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float x = 0.1;
    int steps = 0;
    
    while (x < 10.0 && steps < 50) {
        x = x * 1.1 + 0.01;
        steps++;
        
        if (x > uv.x * 10.0) break;
    }
    
    float y = fract(x);
    fragColor = vec4(y, float(steps) / 50.0, 0.0, 1.0);
}

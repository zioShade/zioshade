// Test: do-while with complex condition
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float x = uv.x;
    int iters = 0;
    
    // Newton's method for sqrt
    float guess = 1.0;
    do {
        float prev = guess;
        guess = (guess + x / guess) * 0.5;
        iters++;
        if (abs(guess - prev) < 0.001) break;
    } while (iters < 20);
    
    fragColor = vec4(guess, float(iters) / 20.0, 0.0, 1.0);
}

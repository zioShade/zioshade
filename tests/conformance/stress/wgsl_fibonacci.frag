// Test: recursive-looking fibonacci (actually iterative with loop)
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    int n = int(gl_FragCoord.x) % 20;
    
    int fib_prev = 0;
    int fib_curr = 1;
    
    for (int i = 0; i < n; i++) {
        int temp = fib_curr;
        fib_curr = fib_prev + fib_curr;
        fib_prev = temp;
    }
    
    float result = float(fib_prev) / 1000.0;
    fragColor = vec4(result, float(n) / 20.0, 0.0, 1.0);
}

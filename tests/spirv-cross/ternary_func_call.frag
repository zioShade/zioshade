#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    // Nested ternary with function calls
    float a = x > 200.0 ? sin(x * 0.1) : cos(x * 0.1);
    float b = x < 100.0 ? abs(x - 150.0) : sqrt(x);
    float c = mix(a, b, step(150.0, x));
    fragColor = vec4(c * 0.5);
}

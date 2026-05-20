#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    // Deeply nested ternaries
    float a = x > 200.0 ? 1.0 : x > 150.0 ? 0.8 : x > 100.0 ? 0.6 : x > 50.0 ? 0.4 : x > 25.0 ? 0.2 : 0.0;
    float b = x < 100.0 ? (x < 50.0 ? 0.1 : 0.3) : (x < 200.0 ? 0.5 : 0.7);
    float c = (x > 50.0 && x < 150.0) ? 1.0 : (x > 150.0 ? 0.5 : 0.0);
    fragColor = vec4(a, b, c, 1.0);
}

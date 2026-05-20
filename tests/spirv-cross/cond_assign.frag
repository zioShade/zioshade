#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    float y = gl_FragCoord.y;
    float a = 0.0;
    float b = 0.0;
    // Conditional assignment patterns
    if (x > 100.0) a = 1.0; else a = 0.5;
    if (y > 100.0) { b = 2.0; } else { b = 1.0; }
    a += (x > 200.0) ? 0.3 : 0.0;
    b *= (y < 50.0) ? 0.5 : 1.0;
    fragColor = vec4(a, b, 0.0, 1.0);
}

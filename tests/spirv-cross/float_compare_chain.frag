#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    float y = gl_FragCoord.y;
    // Chain of float comparisons
    bool b1 = x > 100.0;
    bool b2 = y < 100.0;
    bool b3 = x >= 50.0 && x <= 200.0;
    bool b4 = y != 50.0 || y == 100.0;
    bool b5 = !(x < 0.0) && !(y > 300.0);
    float r = b1 ? 1.0 : 0.0;
    float g = b2 ? 1.0 : 0.0;
    float b = b3 ? 1.0 : 0.0;
    float a = (b4 && b5) ? 1.0 : 0.0;
    fragColor = vec4(r, g, b, a);
}

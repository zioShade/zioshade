#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    float y = gl_FragCoord.y;
    // Mixed int/float/bool conditions
    bool in_circle = (x - 150.0) * (x - 150.0) + (y - 150.0) * (y - 150.0) < 10000.0;
    bool in_rect = x > 50.0 && x < 250.0 && y > 50.0 && y < 250.0;
    int quadrant = int(x > 150.0) * 2 + int(y > 150.0);
    bool in_region = in_circle || in_rect;
    float r = in_region ? 1.0 : 0.0;
    float g = in_circle && in_rect ? 0.5 : 0.0;
    float b = float(quadrant) / 4.0;
    fragColor = vec4(r, g, b, 1.0);
}

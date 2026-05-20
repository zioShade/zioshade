#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float a = gl_FragCoord.x * 0.01;
    float b = gl_FragCoord.y * 0.01;
    float sa = sin(a);
    float ca = cos(a);
    float sb = sin(b);
    float cb = cos(b);
    // Double angle: sin(2a) = 2*sin(a)*cos(a)
    float sin2a = 2.0 * sa * ca;
    // Sum formula: sin(a+b) = sin(a)*cos(b) + cos(a)*sin(b)
    float sinab = sa * cb + ca * sb;
    // atan2 roundtrip
    float angle = atan(sinab, cos(a) * cb - sa * sb);
    fragColor = vec4(sin2a * 0.5 + 0.5, sinab * 0.5 + 0.5, angle / 6.28 + 0.5, 1.0);
}

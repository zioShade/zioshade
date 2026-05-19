#version 450

// Test: large constant expression
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    const float PI = 3.14159265;
    const float TAU = PI * 2.0;
    const float GOLDEN = 1.618033988;
    const float SQRT2 = 1.41421356;
    const float LN2 = 0.69314718;

    float a = sin(uv.x * TAU) * 0.5 + 0.5;
    float b = cos(uv.y * PI) * 0.5 + 0.5;
    float c = log(2.0) / LN2;
    float d = GOLDEN * uv.x;
    float e = SQRT2 * uv.y;

    gl_FragColor = vec4(a * b, c * 0.5, (d + e) * 0.3, 1.0);
}

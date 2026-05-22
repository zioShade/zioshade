#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Deeply nested ternary chain (5 levels) with function calls
    float v = uv.x > 0.5
        ? (uv.y > 0.5
            ? sin(uv.x * 10.0)
            : cos(uv.y * 10.0))
        : (uv.y > 0.3
            ? (uv.x > 0.2
                ? tan(uv.x * 3.0)
                : sqrt(abs(uv.y)))
            : log(1.0 + abs(uv.x + uv.y)));

    // Nested ternary with same variable in both branches (phi test)
    float a = 0.5;
    a = uv.x > 0.5 ? a + 0.3 : a - 0.1;
    a = uv.y > 0.5 ? a * 2.0 : a / 2.0;
    a = v > 0.0 ? a + v : a - v;

    // Chained conditional with compound assignment
    float b = 1.0;
    if (uv.x > 0.25) b += 0.2;
    if (uv.x > 0.50) b *= 1.5;
    if (uv.x > 0.75) b -= 0.3;
    else b /= 2.0;

    fragColor = vec4(clamp(vec3(v * 0.5 + a * 0.3 + b * 0.2), 0.0, 1.0), 1.0);
}

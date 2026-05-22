#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Do-while with break and compound condition
    float x = uv.x;
    int n = 0;
    do {
        x = x * x + 0.1;
        n++;
        if (x > 3.0) break;
    } while (n < 20 && x < 4.0);

    vec3 col = vec3(x * 0.1, float(n) * 0.05, 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 310 es
precision highp float;
out vec4 fragColor;

// Do-while with multiple variables and break condition
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float x = uv.x * 2.0 - 1.0;
    float y = uv.y * 2.0 - 1.0;
    int n = 0;
    float zx = x;
    float zy = y;

    do {
        float tmp = zx * zx - zy * zy + x;
        zy = 2.0 * zx * zy + y;
        zx = tmp;
        n++;
    } while (zx * zx + zy * zy < 4.0 && n < 25);

    float t = float(n) / 25.0;
    vec3 col = mix(vec3(0.0, 0.0, 0.2), vec3(0.8, 0.4, 0.1), t);
    if (n >= 25) col = vec3(0.0);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

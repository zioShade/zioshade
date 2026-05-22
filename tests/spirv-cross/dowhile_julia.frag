#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Do-while Julia set iteration
    float zx = uv.x * 2.0 - 1.0;
    float zy = uv.y * 2.0 - 1.0;
    int iter = 0;

    for (int i = 0; i < 20; i++) {
        float xnew = zx * zx - zy * zy + (uv.x * 2.0 - 1.0);
        float ynew = 2.0 * zx * zy + (uv.y * 2.0 - 1.0);
        zx = xnew;
        zy = ynew;
        iter = i;
        if (zx * zx + zy * zy > 4.0) break;
    }

    float t = float(iter) / 20.0;
    vec3 col = mix(vec3(0.0), vec3(0.8, 0.4, 0.2), t);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // QR code style grid pattern
    float scale = 8.0;
    vec2 cell = floor(uv * scale);
    vec2 f = fract(uv * scale);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    float module = step(0.5, h);
    // Finder patterns (3 corners)
    float finder = 0.0;
    for (int fx = 0; fx < 2; fx++) {
        for (int fy = 0; fy < 2; fy++) {
            if (fx == 1 && fy == 1) continue;
            vec2 finder_origin = vec2(float(fx), float(fy)) * (scale - 3.0);
            vec2 fp = cell - finder_origin;
            float ring1 = step(0.0, fp.x) * step(fp.x, 6.0) * step(0.0, fp.y) * step(fp.y, 6.0);
            float ring2 = step(1.0, fp.x) * step(fp.x, 5.0) * step(1.0, fp.y) * step(fp.y, 5.0);
            float ring3 = step(2.0, fp.x) * step(fp.x, 4.0) * step(2.0, fp.y) * step(fp.y, 4.0);
            finder = max(finder, ring1 * (1.0 - ring2) + ring3);
        }
    }
    float fill = max(module, finder);
    vec3 col = vec3(1.0 - fill);
    fragColor = vec4(col, 1.0);
}

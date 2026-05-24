#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 color = vec3(0.0);

    // Mandelbrot-like iteration
    vec2 c = (uv - 0.5) * 4.0;
    vec2 z = vec2(0.0);
    int iter = 0;
    for (int i = 0; i < 32; i++) {
        float x2 = z.x * z.x;
        float y2 = z.y * z.y;
        if (x2 + y2 > 4.0) break;
        z = vec2(x2 - y2 + c.x, 2.0 * z.x * z.y + c.y);
        iter = i;
    }

    float t = float(iter) / 32.0;
    color = mix(vec3(0.0, 0.0, 0.2), vec3(0.8, 0.4, 0.1), t);
    if (iter == 31) color = vec3(0.0);

    fragColor = vec4(color, 1.0);
}

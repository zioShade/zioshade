#version 430
layout(location = 0) out vec4 FragColor;

// Test: mandelbrot set (simple, limited iterations)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 c = (uv - 0.5) * 3.0;
    vec2 z = vec2(0.0);

    int iter = 0;
    for (int i = 0; i < 16; i++) {
        float x = z.x * z.x - z.y * z.y + c.x;
        float y = 2.0 * z.x * z.y + c.y;
        z = vec2(x, y);
        if (dot(z, z) > 4.0) break;
        iter++;
    }

    float t = float(iter) / 16.0;
    vec3 col = vec3(t, t * t, sqrt(t));
    FragColor = vec4(col, 1.0);
}

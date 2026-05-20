#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Mandelbrot set (iterative z = z^2 + c)
    vec2 c = vec2(uv.x * 3.0 - 2.0, uv.y * 3.0 - 1.5);
    vec2 z = vec2(0.0);
    float iter = 0.0;
    for (int i = 0; i < 30; i++) {
        if (dot(z, z) > 4.0) break;
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        iter += 1.0;
    }
    float t = iter / 30.0;
    vec3 col = vec3(t, t * t, t * t * t);
    if (dot(z, z) <= 4.0) col = vec3(0.0);
    fragColor = vec4(col, 1.0);
}

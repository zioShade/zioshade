#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Mandelbrot with escape coloring
    vec2 c = vec2(uv.x * 3.0 - 2.0, uv.y * 3.0 - 1.5);
    vec2 z = vec2(0.0);
    float iter = 0.0;
    for (int i = 0; i < 40; i++) {
        if (dot(z, z) > 4.0) break;
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        iter += 1.0;
    }
    float t = iter / 40.0;
    vec3 col = vec3(0.0);
    if (dot(z, z) <= 4.0) {
        col = vec3(0.0);
    } else {
        col = vec3(t, t * t, t * t * t);
        col += vec3(0.1, 0.0, 0.15) * sin(t * 6.28);
    }
    fragColor = vec4(col, 1.0);
}

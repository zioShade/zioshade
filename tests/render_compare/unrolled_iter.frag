#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    // Mandelbrot-like iteration (fixed count, no loop needed)
    vec2 c = (uv - 0.5) * 3.0;
    vec2 z = vec2(0.0);
    z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    float mag = length(z);
    vec3 col = vec3(mag * 0.3, mag * 0.15, 1.0 - mag * 0.2);
    FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

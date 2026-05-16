#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // UV wrapping with mod
    vec2 wrapped = mod(uv * 3.0, 1.0);

    // Mandelbrot set at low resolution
    vec2 c = (wrapped - 0.5) * 3.0;
    vec2 z = vec2(0.0);
    float iter = 0.0;

    for (int i = 0; i < 32; i++) {
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        if (dot(z, z) > 4.0) break;
        iter += 1.0;
    }

    float t = iter / 32.0;
    vec3 col = vec3(t, t * t, sqrt(t));
    fragColor = vec4(col, 1.0);
}

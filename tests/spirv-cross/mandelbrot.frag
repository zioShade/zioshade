#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Mandelbrot set — tests loops, complex arithmetic
    float x0 = uv.x * 3.5 - 2.5;
    float y0 = uv.y * 2.0 - 1.0;
    float x = 0.0;
    float y = 0.0;
    int iter = 0;
    for (int i = 0; i < 64; i++) {
        float xtemp = x * x - y * y + x0;
        y = 2.0 * x * y + y0;
        x = xtemp;
        if (x * x + y * y > 4.0) break;
        iter++;
    }
    float t = float(iter) / 64.0;
    fragColor = vec4(t, t * 0.5, 1.0 - t, 1.0);
}

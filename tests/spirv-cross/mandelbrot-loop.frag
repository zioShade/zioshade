#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Mandelbrot set - exercises loops, complex math, color mapping
void main() {
    vec2 c = (uv - 0.5) * 3.0;
    vec2 z = vec2(0.0);
    int iter = 0;
    const int maxIter = 32;
    
    for (int i = 0; i < maxIter; i++) {
        float x = z.x * z.x - z.y * z.y + c.x;
        float y = 2.0 * z.x * z.y + c.y;
        z = vec2(x, y);
        if (dot(z, z) > 4.0) {
            iter = i;
            break;
        }
    }
    
    float t = float(iter) / float(maxIter);
    vec3 col = vec3(t, t * t, sqrt(t));
    fragColor = vec4(col, 1.0);
}

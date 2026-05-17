#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mandelbrot with smooth iteration count
void main() {
    vec2 c = (uv - 0.5) * 3.0;
    vec2 z = vec2(0.0);
    float iter = 0.0;
    
    for (int i = 0; i < 64; i++) {
        if (dot(z, z) > 4.0) break;
        z = vec2(z.x * z.x - z.y * z.y + c.x, 2.0 * z.x * z.y + c.y);
        iter += 1.0;
    }
    
    // Smooth iteration count
    if (dot(z, z) > 4.0) {
        float sl = iter - log2(log2(dot(z, z))) + 4.0;
        float t = sl / 64.0;
        vec3 col = 0.5 + 0.5 * cos(3.0 + t * 6.28 * 5.0 + vec3(0.0, 0.6, 1.0));
        fragColor = vec4(col, 1.0);
    } else {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    }
}

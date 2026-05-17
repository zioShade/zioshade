#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test recursive-ish pattern using iteration count
void main() {
    vec2 z = uv * 3.0 - 1.5;
    vec2 c = z;
    
    float iter = 0.0;
    for (int i = 0; i < 32; i++) {
        if (dot(z, z) > 4.0) break;
        
        // Mandelbrot with twist
        float xnew = z.x * z.x - z.y * z.y + c.x;
        float ynew = 2.0 * z.x * z.y + c.y;
        z = vec2(xnew, ynew);
        iter += 1.0;
    }
    
    // Smooth coloring
    if (iter < 31.0) {
        iter = iter - log2(log2(dot(z, z))) + 4.0;
    }
    
    float t = iter / 32.0;
    vec3 col = 0.5 + 0.5 * cos(3.0 + t * 6.28 * 4.0 + vec3(0.0, 0.6, 1.0));
    if (iter >= 31.0) col = vec3(0.0);
    
    fragColor = vec4(col, 1.0);
}

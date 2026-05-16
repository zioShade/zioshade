#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Complex number operations (Mandelbrot variant with burning ship)
void main() {
    vec2 c = (uv - 0.5) * vec2(3.5, 2.5);
    c.y = -c.y;
    c += vec2(-0.5, 0.0);
    
    vec2 z = vec2(0.0);
    float iter = 0.0;
    
    for (int i = 0; i < 48; i++) {
        // Burning ship: abs before multiply
        z = vec2(abs(z.x), abs(z.y));
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        
        if (dot(z, z) > 4.0) break;
        iter += 1.0;
    }
    
    float t = iter / 48.0;
    vec3 col = vec3(sqrt(t), t * t, sin(t * 3.14));
    if (iter >= 47.0) col = vec3(0.0);
    
    fragColor = vec4(col, 1.0);
}

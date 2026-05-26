// Test: Mandelbrot set iteration
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    vec2 c = (uv - 0.5) * vec2(3.5, 2.5);
    
    vec2 z = vec2(0.0);
    int iter = 0;
    int maxIter = 100;
    
    for (int i = 0; i < 100; i++) {
        float x = z.x * z.x - z.y * z.y + c.x;
        float y = 2.0 * z.x * z.y + c.y;
        z = vec2(x, y);
        
        if (dot(z, z) > 4.0) {
            iter = i;
            break;
        }
        iter = i;
    }
    
    float t = float(iter) / float(maxIter);
    vec3 color = vec3(t, t * t, sqrt(t));
    
    if (iter == maxIter - 1) color = vec3(0.0);
    
    fragColor = vec4(color, 1.0);
}

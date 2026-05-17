#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Lorenz attractor projection (2D slice)
void main() {
    float x = 0.1, y = 0.0, z = 0.0;
    float sigma = 10.0, rho = 28.0, beta = 2.667;
    float dt = 0.005;
    
    float sum = 0.0;
    for (int i = 0; i < 200; i++) {
        float dx = sigma * (y - x);
        float dy = x * (rho - z) - y;
        float dz = x * y - beta * z;
        x += dx * dt;
        y += dy * dt;
        z += dz * dt;
        
        // Accumulate trajectory density
        vec2 p = vec2(x / 30.0 + 0.5, y / 30.0 + 0.5);
        sum += smoothstep(0.05, 0.0, length(uv - p)) * 0.1;
    }
    
    sum = min(sum, 1.0);
    vec3 col = vec3(sum * 0.3, sum * 0.7, sum);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

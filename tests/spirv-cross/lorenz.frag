#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Lorenz attractor (xz projection)
    float x = 0.1;
    float y = 0.0;
    float z = 0.0;
    float sigma = 10.0;
    float rho = 28.0;
    float beta = 8.0 / 3.0;
    float dt = 0.005;
    float min_d = 1.0;
    for (int i = 0; i < 200; i++) {
        float dx = sigma * (y - x) * dt;
        float dy = (x * (rho - z) - y) * dt;
        float dz = (x * y - beta * z) * dt;
        x += dx;
        y += dy;
        z += dz;
        // Project xz plane to screen
        vec2 pt = vec2(x, z) * 0.025 - vec2(0.0, 0.7);
        float d = length(uv - pt);
        min_d = min(min_d, d);
    }
    float line = smoothstep(0.008, 0.003, min_d);
    vec3 col = vec3(0.02) + vec3(0.9, 0.5, 0.1) * line;
    fragColor = vec4(col, 1.0);
}

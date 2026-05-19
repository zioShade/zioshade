#version 430
layout(location = 0) out vec4 FragColor;

// Test: julia set fractal
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 z = (uv - 0.5) * 3.0;
    vec2 c = vec2(-0.7, 0.27015);

    int iter = 0;
    for (int i = 0; i < 16; i++) {
        float x = z.x * z.x - z.y * z.y + c.x;
        float y = 2.0 * z.x * z.y + c.y;
        z = vec2(x, y);
        if (dot(z, z) > 4.0) break;
        iter++;
    }

    float t = float(iter) / 16.0;
    FragColor = vec4(0.5 + 0.5 * cos(6.28 * (t + vec3(0.0, 0.33, 0.67))), 1.0);
}

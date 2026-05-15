#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Julia set fractal
    vec2 c = vec2(-0.7, 0.27015);
    vec2 z = uv * 3.0 - vec2(1.5);
    int iter = 0;
    for (int i = 0; i < 50; i++) {
        float x = z.x * z.x - z.y * z.y + c.x;
        float y = 2.0 * z.x * z.y + c.y;
        z = vec2(x, y);
        if (dot(z, z) > 4.0) break;
        iter++;
    }
    float t = float(iter) / 50.0;
    vec3 color = vec3(t, t * t, t * t * t);
    fragColor = vec4(color, 1.0);
}

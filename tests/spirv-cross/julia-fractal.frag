#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Julia set fractal
    vec2 c = vec2(-0.7, 0.27015);
    vec2 z = (uv - 0.5) * 3.0;

    float iter = 0.0;
    for (int i = 0; i < 64; i++) {
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        if (dot(z, z) > 4.0) break;
        iter += 1.0;
    }

    float t = iter / 64.0;
    vec3 col = vec3(t, t * t, sqrt(t));
    if (iter >= 63.0) col = vec3(0.0);

    fragColor = vec4(col, 1.0);
}

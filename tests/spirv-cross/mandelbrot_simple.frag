#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 c = (uv - 0.5) * vec2(3.5, 2.5) + vec2(-0.5, 0.0);
    vec2 z = vec2(0.0);
    float iter = 0.0;
    for (int i = 0; i < 64; i++) {
        if (dot(z, z) > 4.0) break;
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        iter += 1.0;
    }
    float t = iter / 64.0;
    vec3 col = vec3(t, t * t, t * t * t);
    if (iter >= 64.0) col = vec3(0.0);
    FragColor = vec4(col, 1.0);
}

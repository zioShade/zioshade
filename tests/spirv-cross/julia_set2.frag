#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Simple Julia set
    vec2 c = vec2(-0.7, 0.27015);
    vec2 z = uv * 2.0;
    float iter = 0.0;
    for (int i = 0; i < 30; i++) {
        if (dot(z, z) > 4.0) break;
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        iter += 1.0;
    }
    float t = iter / 30.0;
    vec3 col = vec3(t * t, t, t * t * t);
    if (iter >= 30.0) col = vec3(0.0);
    fragColor = vec4(col, 1.0);
}

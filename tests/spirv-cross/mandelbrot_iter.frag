#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) * 0.01;
    vec2 z = vec2(0.0);
    int iter = 0;
    for (int i = 0; i < 50; i++) {
        if (dot(z, z) > 4.0) break;
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + uv;
        iter = i;
    }
    float t = float(iter) / 50.0;
    vec3 col = vec3(t, t * 0.5, 1.0 - t);
    fragColor = vec4(col, 1.0);
}

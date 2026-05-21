#version 310 es
precision highp float;
out vec4 fragColor;

// Test: do-while with complex exit condition
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec2 z = uv * 2.0;
    vec2 c = vec2(-0.7, 0.27015);
    int iter = 0;
    do {
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        iter++;
    } while (dot(z, z) < 4.0 && iter < 50);
    float t = float(iter) / 50.0;
    vec3 col = vec3(t * 0.5, t * 0.3, t);
    if (iter >= 50) col = vec3(0.0);
    fragColor = vec4(col, 1.0);
}

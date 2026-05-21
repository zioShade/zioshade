#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Test: complex while loop with multiple exits
    float x = uv.x;
    float y = uv.y;
    int iter = 0;
    while (iter < 20) {
        float nx = x * x - y * y + uv.x * 0.5;
        float ny = 2.0 * x * y + uv.y * 0.5;
        x = nx;
        y = ny;
        iter++;
        if (x * x + y * y > 4.0) break;
    }
    float t = float(iter) / 20.0;
    vec3 col = vec3(t, t * t * 0.5, t * t * t * 0.3);
    if (iter >= 20) col = vec3(0.0);
    fragColor = vec4(col, 1.0);
}

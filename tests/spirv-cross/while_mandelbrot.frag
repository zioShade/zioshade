#version 310 es
precision highp float;
out vec4 fragColor;

// While loop with complex condition modifying tracked state
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float x = uv.x;
    float y = uv.y;
    int steps = 0;

    while (x * x + y * y < 4.0 && steps < 50) {
        float nx = x * x - y * y + uv.x;
        float ny = 2.0 * x * y + uv.y;
        x = nx;
        y = ny;
        steps++;
        if (x > 10.0 || y > 10.0) break;
    }

    float t = float(steps) / 50.0;
    vec3 col = vec3(t, sqrt(t), 1.0 - t);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

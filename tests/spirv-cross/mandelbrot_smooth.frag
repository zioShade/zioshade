#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // While loop with complex break condition + tracking state
    float x = uv.x;
    float y = uv.y;
    int iter = 0;
    float z = 0.0;

    while (iter < 20) {
        float xnew = x * x - y * y + uv.x;
        float ynew = 2.0 * x * y + uv.y;
        x = xnew;
        y = ynew;
        z = x * x + y * y;
        iter++;
        if (z > 4.0) break;
    }

    // Smooth coloring based on iteration count
    float t = float(iter) / 20.0;
    vec3 col;
    if (z > 4.0) {
        // Escaped — color by iteration
        float sl = float(iter) - log2(log2(z)) + 4.0;
        col = 0.5 + 0.5 * cos(3.0 + sl * 0.15 + vec3(0.0, 0.6, 1.0));
    } else {
        // In set — black
        col = vec3(0.0);
    }

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

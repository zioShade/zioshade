#version 450

// Test: do-while with early exit
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float val = uv.x;
    float prev = -1.0;
    int iter = 0;

    do {
        prev = val;
        val = val * val;
        iter++;
    } while (abs(val - prev) > 0.01 && iter < 10);

    gl_FragColor = vec4(val, float(iter) / 10.0, uv.y, 1.0);
}

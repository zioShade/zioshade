// Tests: while loop with early return from nested if
precision mediump float;
uniform vec2 u_resolution;

float search(float target) {
    float x = 0.0;
    int i = 0;
    while (i < 20) {
        x = x * x + 0.3;
        if (x > target) return float(i) / 20.0;
        i++;
    }
    return 1.0;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float r = search(uv.x);
    float g = search(uv.y);
    gl_FragColor = vec4(r, g, 0.3, 1.0);
}

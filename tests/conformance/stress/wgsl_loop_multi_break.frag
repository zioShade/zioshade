// Tests: complex loop with multiple breaks
#version 450
uniform float u_val;

void main() {
    float x = u_val;
    float best = 0.0;
    for (int i = 0; i < 10; i++) {
        float t = sin(float(i) * 0.5 + x);
        if (t > 0.9) {
            best = t;
            break;
        }
        if (t > best) best = t;
    }
    gl_FragColor = vec4(best, u_val, 0.0, 1.0);
}

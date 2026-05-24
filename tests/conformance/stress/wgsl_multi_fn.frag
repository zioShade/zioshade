// Tests: multiple function calls with return values
#version 450
uniform float u_val;

float add(float a, float b) {
    return a + b;
}

float mul(float a, float b) {
    return a * b;
}

float clamp01(float x) {
    return clamp(x, 0.0, 1.0);
}

void main() {
    float a = add(u_val, 0.5);
    float b = mul(a, 2.0);
    float c = clamp01(b);
    gl_FragColor = vec4(c, a, b, 1.0);
}

// Tests: nested function calls
#version 450
uniform float u_val;

float square(float x) { return x * x; }
float add(float a, float b) { return a + b; }

void main() {
    float a = square(u_val);
    float b = add(a, 1.0);
    float c = square(add(b, 0.5));
    gl_FragColor = vec4(c, a, b, 1.0);
}

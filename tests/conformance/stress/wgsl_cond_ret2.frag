// Tests: conditional return from function
#version 450
uniform float u_val;

float process(float x) {
    if (x > 1.0) return x * 2.0;
    if (x > 0.5) return x + 0.5;
    return x * 0.5;
}

void main() {
    float r = process(u_val);
    gl_FragColor = vec4(r, 0.0, 0.0, 1.0);
}

// Tests: conditional return from function
#version 450
uniform float u_val;

float saturate(float x) {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

void main() {
    float s = saturate(u_val);
    gl_FragColor = vec4(s, s, s, 1.0);
}

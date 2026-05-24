// Tests: ternary operator chains
#version 450
uniform float u_val;

void main() {
    float x = u_val;
    float result = x > 0.5 ? 1.0 : (x > 0.25 ? 0.5 : 0.0);
    float result2 = x < 0.1 ? 0.1 : (x < 0.9 ? x : 0.9);
    gl_FragColor = vec4(result, result2, 0.0, 1.0);
}

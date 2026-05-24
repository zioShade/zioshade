// Tests: array initialization and indexing
#version 450
uniform float u_val;

void main() {
    float arr[4];
    arr[0] = u_val;
    arr[1] = u_val * 0.5;
    arr[2] = u_val * 0.25;
    arr[3] = u_val * 0.125;
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        sum += arr[i];
    }
    gl_FragColor = vec4(sum, 0.0, 0.0, 1.0);
}

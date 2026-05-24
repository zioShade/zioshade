// Tests: array initialization and dynamic indexing
#version 450
uniform float u_val;

void main() {
    float arr[5];
    arr[0] = 0.1;
    arr[1] = 0.2;
    arr[2] = 0.3;
    arr[3] = 0.4;
    arr[4] = 0.5;
    
    int idx = int(u_val * 4.0);
    idx = clamp(idx, 0, 4);
    float result = arr[idx];
    
    gl_FragColor = vec4(result, 0.0, 0.0, 1.0);
}

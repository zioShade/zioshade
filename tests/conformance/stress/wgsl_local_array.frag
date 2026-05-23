#version 450
out vec4 fragColor;

void main() {
    float arr[4];
    arr[0] = 0.1;
    arr[1] = 0.3;
    arr[2] = 0.5;
    arr[3] = 0.7;
    int idx = int(gl_FragCoord.x) % 4;
    float val = arr[idx];
    fragColor = vec4(val, val, val, 1.0);
}

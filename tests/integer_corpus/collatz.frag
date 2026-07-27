#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int n = (int(gl_FragCoord.x) & 63) + 1;
    int steps = 0;
    while (n > 1 && steps < 1000) {
        if ((n & 1) == 0) n = n >> 1; else n = 3*n + 1;
        steps++;
    }
    FragColor = vec4(float(steps & 255)/255.0, float(n & 255)/255.0, 0.0, 1.0);
}

#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int n = (int(gl_FragCoord.x) & 31) + 1;
    int a = 0, b = 1;
    for (int i = 0; i < n; i++) { int c = (a + b) & 1023; a = b; b = c; }
    float v = float(a) / 1023.0;
    FragColor = vec4(v, v, v, 1.0);
}

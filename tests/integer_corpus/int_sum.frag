#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int n = int(gl_FragCoord.x) & 15;
    int s = 0;
    for (int i = 1; i <= n; i++) s += i;       // triangular number, integer-exact
    float v = float(s & 255) / 255.0;
    FragColor = vec4(v, v, v, 1.0);
}

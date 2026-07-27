#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int a = (int(gl_FragCoord.x) & 31) + 1;
    int b = (int(gl_FragCoord.y) & 31) + 1;
    while (b != 0) { int t = a % b; a = b; b = t; }
    float v = float(a) / 32.0;
    FragColor = vec4(v, v, v, 1.0);
}

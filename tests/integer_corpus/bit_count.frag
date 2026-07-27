#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int x = int(gl_FragCoord.x) ^ int(gl_FragCoord.y);
    int c = 0;
    for (int i = 0; i < 16; i++) c += (x >> i) & 1;
    float v = float(c) / 16.0;
    FragColor = vec4(v, v, v, 1.0);
}

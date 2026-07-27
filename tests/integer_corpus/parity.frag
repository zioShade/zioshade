#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int x = int(gl_FragCoord.x) + int(gl_FragCoord.y);
    int p = 0;
    for (int i = 0; i < 16; i++) p ^= (x >> i) & 1;
    FragColor = vec4(float(p), float(p), float(p), 1.0);
}

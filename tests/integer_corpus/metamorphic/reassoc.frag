#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int a = int(gl_FragCoord.x) & 1023;
    int b = int(gl_FragCoord.y) & 1023;
    int c = a ^ b;
    int s = (a + b) + c;             // left-associated
    FragColor = vec4(float(s & 1023) / 1023.0);
}

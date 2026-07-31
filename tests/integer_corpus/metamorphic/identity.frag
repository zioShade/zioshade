#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int x = int(gl_FragCoord.x) ^ int(gl_FragCoord.y);
    int c = x + 0;
    c = c * 1;
    c = c | 0;
    FragColor = vec4(float(c & 255) / 255.0);
}

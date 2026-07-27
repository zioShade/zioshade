#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int x = int(gl_FragCoord.x) & 15;
    int y = int(gl_FragCoord.y) & 15;
    float r = (x > y) ? 1.0 : 0.0;
    float g = (x == y) ? 1.0 : 0.0;
    float b = (x < y) ? 1.0 : 0.0;
    FragColor = vec4(r, g, b, 1.0);
}

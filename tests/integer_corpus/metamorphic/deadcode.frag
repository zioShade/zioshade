#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int x = int(gl_FragCoord.x) & 63;
    int y = x;
    int unused = (y * 7) ^ (y + 3);  // dead
    FragColor = vec4(float(y & 63) / 63.0);
}

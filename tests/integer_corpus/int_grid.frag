#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int gx = (int(gl_FragCoord.x) >> 3) & 1;
    int gy = (int(gl_FragCoord.y) >> 3) & 1;
    float c = float(gx ^ gy);
    FragColor = vec4(c, c, c, 1.0);
}

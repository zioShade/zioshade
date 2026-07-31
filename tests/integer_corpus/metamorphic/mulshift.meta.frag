#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int x = int(gl_FragCoord.x) & 31;
    int p = x << 3;                  // x*8 == x<<3 (wrapping int; x in [0,31])
    FragColor = vec4(float(p & 255) / 255.0);
}

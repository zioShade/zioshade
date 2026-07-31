#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int x = int(gl_FragCoord.x) & 63;
    FragColor = vec4(float(x & 63) / 63.0);  // y=x inlined; dead code removed
}

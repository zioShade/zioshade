#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int a = int(gl_FragCoord.x) & 511;
    int b = int(gl_FragCoord.y) & 511;
    int d = a + (~b + 1);            // -b == ~b+1, so a-b == a+(~b+1) (wrapping int)
    FragColor = vec4(float(d & 511) / 511.0);
}

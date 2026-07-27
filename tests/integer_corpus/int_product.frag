#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int n = (int(gl_FragCoord.y) & 7) + 1;
    int p = 1;
    for (int i = 1; i <= n; i++) p *= i;       // factorial, integer-exact
    FragColor = vec4(float(p & 255)/255.0, float((p>>4)&255)/255.0, float((p>>8)&255)/255.0, 1.0);
}

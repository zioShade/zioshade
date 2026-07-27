#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int n = (int(gl_FragCoord.x) & 7) + 1;
    int total = 0;
    for (int i = 0; i < n; i++)
        for (int j = 0; j <= i; j++) total += (i * j) & 7;
    FragColor = vec4(float(total & 255)/255.0, float((total>>3)&255)/255.0, float((total>>6)&255)/255.0, 1.0);
}

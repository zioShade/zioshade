#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    float a[4];
    a[0] = 0.2; a[1] = 0.4; a[2] = 0.6; a[3] = 0.8;
    float sum = 0.0;
    for (int i = 0; i < 4; i++) sum += a[i];
    FragColor = vec4(sum / 4.0, sum / 2.0, sum, 1.0);
}

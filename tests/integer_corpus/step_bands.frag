#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int band = int(gl_FragCoord.x) / 32;       // integer division — exact
    vec3 col;
    if (band == 0) col = vec3(1.0, 0.0, 0.0);
    else if (band == 1) col = vec3(0.0, 1.0, 0.0);
    else if (band == 2) col = vec3(0.0, 0.0, 1.0);
    else col = vec3(1.0, 1.0, 0.0);
    FragColor = vec4(col, 1.0);
}

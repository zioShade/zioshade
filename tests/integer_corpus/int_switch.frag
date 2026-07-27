#version 450
layout(location=0) out vec4 FragColor;
void main() {
    int m = int(gl_FragCoord.x) & 3;
    vec3 col = vec3(0.0);
    switch (m) {            // fallthrough accumulation, integer selector
        case 3: col += vec3(0.25);
        case 2: col += vec3(0.25);
        case 1: col += vec3(0.25);
        case 0: col += vec3(0.25);
    }
    FragColor = vec4(col, 1.0);
}

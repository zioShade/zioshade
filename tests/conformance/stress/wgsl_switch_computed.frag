// Tests: complex switch with computed selector
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    int mode = int(fract(0.7) * 4.0);
    vec3 color;
    switch (mode) {
        case 0: color = vec3(1.0, 0.0, 0.0); break;
        case 1: color = vec3(0.0, 1.0, 0.0); break;
        case 2: color = vec3(0.0, 0.0, 1.0); break;
        case 3: color = vec3(1.0, 1.0, 1.0); break;
        default: color = vec3(0.0); break;
    }
    fragColor = vec4(color, 1.0);
}

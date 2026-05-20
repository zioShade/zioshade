#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    int mode = int(gl_FragCoord.x) % 5;
    vec3 color;
    switch (mode) {
        case 0: color = vec3(1.0, 0.0, 0.0); break;
        case 1: color = vec3(0.0, 1.0, 0.0); break;
        case 2: color = vec3(0.0, 0.0, 1.0); break;
        default: color = vec3(0.5); break;
    }
    fragColor = vec4(color, 1.0);
}

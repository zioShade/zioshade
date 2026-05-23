#version 450
layout(location = 0) out vec4 fragColor;
layout(location = 0) in flat int mode;

void main() {
    float val = 0.0;
    switch (mode) {
        case 0: val = 1.0; break;
        case 1: val = 0.5; break;
        case 2: val = 0.25; break;
        default: val = 0.0; break;
    }
    fragColor = vec4(val, val, val, 1.0);
}

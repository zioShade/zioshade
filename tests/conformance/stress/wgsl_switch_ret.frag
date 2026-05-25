// Tests: complex switch with return values
#version 450
layout(location = 0) out vec4 fragColor;
uniform int u_mode;

vec3 getColor(int mode) {
    switch (mode) {
        case 0: return vec3(1.0, 0.0, 0.0);
        case 1: return vec3(0.0, 1.0, 0.0);
        case 2: return vec3(0.0, 0.0, 1.0);
        case 3: return vec3(1.0, 1.0, 0.0);
        case 4: return vec3(1.0, 0.0, 1.0);
        default: return vec3(0.5);
    }
}

void main() {
    vec3 c = getColor(u_mode);
    fragColor = vec4(c, 1.0);
}

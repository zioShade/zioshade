// Tests: multiple write targets via phi
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float a = 0.3;
    float b = 0.7;
    float c;

    if (a > 0.5) {
        c = a;
    } else if (b > 0.5) {
        c = b;
    } else {
        c = a + b;
    }

    fragColor = vec4(vec3(c), 1.0);
}

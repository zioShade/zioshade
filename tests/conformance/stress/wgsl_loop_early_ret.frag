// Tests: loop with early return inside if
#version 450
layout(location = 0) out vec4 fragColor;

float search(float target) {
    for (int i = 0; i < 100; i++) {
        float val = float(i) * 0.01;
        if (val > target) {
            return val;
        }
    }
    return 1.0;
}

void main() {
    float r = search(0.5);
    fragColor = vec4(vec3(r), 1.0);
}

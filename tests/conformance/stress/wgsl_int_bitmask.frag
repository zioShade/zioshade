// Tests: integer arithmetic and bitwise operations in loop
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    int mask = 0;
    for (int i = 0; i < 8; i++) {
        int bit = 1 << i;
        if ((i % 2) == 0) {
            mask |= bit;
        }
    }
    float result = float(mask) / 255.0;
    fragColor = vec4(vec3(result), 1.0);
}

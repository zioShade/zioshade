// Tests: nested struct with array member
#version 450
layout(location = 0) out vec4 fragColor;

struct Bucket {
    float values[3];
    float total;
};

void main() {
    Bucket b;
    b.values[0] = 0.1;
    b.values[1] = 0.2;
    b.values[2] = 0.3;
    b.total = b.values[0] + b.values[1] + b.values[2];

    for (int i = 0; i < 3; i++) {
        b.values[i] *= 2.0;
        b.total += b.values[i];
    }
    fragColor = vec4(vec3(fract(b.total)), 1.0);
}

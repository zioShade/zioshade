// Tests: mix of integer and float arithmetic
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    int count = 5;
    float total = 0.0;
    for (int i = 0; i < count; i++) {
        total += float(i + 1) / float(count);
    }
    float avg = total / float(count);
    fragColor = vec4(vec3(avg), 1.0);
}

// Tests: function returning array element
#version 450
layout(location = 0) out vec4 fragColor;

float getElement(int idx) {
    float arr[4];
    arr[0] = 0.1;
    arr[1] = 0.3;
    arr[2] = 0.5;
    arr[3] = 0.7;
    return arr[idx];
}

void main() {
    float a = getElement(0);
    float b = getElement(2);
    fragColor = vec4(a, b, a + b, 1.0);
}

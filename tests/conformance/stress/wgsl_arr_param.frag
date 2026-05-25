// Tests: function with array parameter passed by value
#version 450
layout(location = 0) out vec4 fragColor;

float sumArray(float arr[4]) {
    float s = 0.0;
    for (int i = 0; i < 4; i++) {
        s += arr[i];
    }
    return s;
}

void main() {
    float data[4];
    data[0] = 0.1;
    data[1] = 0.2;
    data[2] = 0.3;
    data[3] = 0.4;
    float result = sumArray(data);
    fragColor = vec4(vec3(result), 1.0);
}

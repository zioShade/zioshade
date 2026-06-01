// Tests: global constants used in function
#version 450
layout(location = 0) in float u_val;
layout(location = 0) out vec4 fragColor;
const float PI = 3.14159265;
const float TWO_PI = 6.28318530;

float wrapAngle(float a) {
    return mod(a, TWO_PI);
}

void main() {
    float angle = u_val * PI;
    float wrapped = wrapAngle(angle);
    fragColor = vec4(sin(wrapped), cos(wrapped), 0.0, 1.0);
}

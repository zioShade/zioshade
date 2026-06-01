#version 450
// Tests: global constants used in function
layout(location = 0) out vec4 fragColor;
layout(binding = 0) uniform U { float u_val; };

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

// Tests: global constants used in function
#version 450
const float PI = 3.14159265;
const float TWO_PI = 6.28318530;

float wrapAngle(float a) {
    return mod(a, TWO_PI);
}

void main() {
    float angle = u_val * PI;
    float wrapped = wrapAngle(angle);
    gl_FragColor = vec4(sin(wrapped), cos(wrapped), 0.0, 1.0);
}

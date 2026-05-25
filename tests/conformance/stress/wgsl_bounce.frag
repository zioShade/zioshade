// Tests: loop with conditional update and phi
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_time;

void main() {
    float pos = 0.0;
    float vel = 1.0;
    for (int i = 0; i < 20; i++) {
        pos += vel * 0.1;
        if (pos > 2.0) {
            vel = -vel * 0.8;
        }
        vel *= 0.99;
    }
    fragColor = vec4(fract(pos), fract(abs(vel)), 0.0, 1.0);
}

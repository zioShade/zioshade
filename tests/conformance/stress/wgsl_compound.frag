// Tests: compound assignment operators
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_val;

void main() {
    float x = u_val;
    x += 0.5;
    x *= 2.0;
    x -= 0.3;
    x /= 3.0;
    vec3 v = vec3(x);
    v += vec3(0.1);
    v *= vec3(2.0);
    fragColor = vec4(v, 1.0);
}

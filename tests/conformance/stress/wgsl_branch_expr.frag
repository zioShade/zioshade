// Tests: branch with complex expression and store forwarding
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_x;

void main() {
    float a = u_x;
    float b = a * a;
    float c;

    if (b > 0.5) {
        c = sqrt(b) + a;
    } else {
        c = b + a * 2.0;
    }

    float d = c * c;
    fragColor = vec4(fract(d), fract(c), 0.0, 1.0);
}

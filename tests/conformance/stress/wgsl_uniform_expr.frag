// Tests: multiple uniforms in expression chain
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_a;
uniform float u_b;
uniform float u_c;

void main() {
    float r = u_a * u_b + u_c;
    float g = u_b / (u_a + 0.001);
    float b = sqrt(u_a * u_a + u_b * u_b + u_c * u_c);
    fragColor = vec4(fract(r), fract(g), fract(b), 1.0);
}

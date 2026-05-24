// Tests: multiple functions with different return types
#version 450
uniform float u_val;

float brightness(float c) {
    return c * 2.0 - 0.5;
}

vec3 colorize(float t) {
    return vec3(t, t * 0.5, 1.0 - t);
}

void main() {
    float b = brightness(u_val);
    vec3 col = colorize(b);
    gl_FragColor = vec4(col, 1.0);
}

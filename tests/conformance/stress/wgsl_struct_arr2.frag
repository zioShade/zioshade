// Tests: struct with nested array iteration
#version 450
uniform float u_val;

struct ColorSet {
    vec3 colors[3];
    float weights[3];
};

void main() {
    ColorSet cs;
    cs.colors[0] = vec3(1.0, 0.0, 0.0);
    cs.colors[1] = vec3(0.0, 1.0, 0.0);
    cs.colors[2] = vec3(0.0, 0.0, 1.0);
    cs.weights[0] = u_val;
    cs.weights[1] = 1.0 - u_val;
    cs.weights[2] = 0.5;
    vec3 result = vec3(0.0);
    for (int i = 0; i < 3; i++) {
        result += cs.colors[i] * cs.weights[i];
    }
    gl_FragColor = vec4(result, 1.0);
}

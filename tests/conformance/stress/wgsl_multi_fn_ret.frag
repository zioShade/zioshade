// Tests: multi-function with different return types
#version 450
uniform float u_val;

float getScale(float t) {
    return t * 2.0 + 0.5;
}

vec3 getColor(float t) {
    return vec3(t, t * 0.5, 0.25);
}

void main() {
    float s = getScale(u_val);
    vec3 c = getColor(s);
    gl_FragColor = vec4(c, 1.0);
}

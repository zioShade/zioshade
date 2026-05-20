#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec3 v = vec3(0.2, 0.4, 0.6);
    vec4 a = vec4(v);
    fragColor = a;
}

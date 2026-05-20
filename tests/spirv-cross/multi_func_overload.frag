#version 310 es
precision highp float;
out vec4 fragColor;

float add(float a, float b) { return a + b; }
vec2 add(vec2 a, vec2 b) { return a + b; }
vec3 add(vec3 a, vec3 b) { return a + b; }
float add(float a, float b, float c) { return a + b + c; }

void main() {
    float f = add(1.0, 2.0);
    vec2 v2 = add(vec2(1.0), vec2(2.0));
    vec3 v3 = add(vec3(1.0, 2.0, 3.0), vec3(4.0, 5.0, 6.0));
    float f3 = add(1.0, 2.0, 3.0);
    fragColor = vec4(f, v2.x, v3.x, f3);
}

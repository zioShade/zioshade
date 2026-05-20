#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float f = 1.0;
    vec2 v2 = vec2(f, f * 2.0);
    vec3 v3a = vec3(v2, f * 3.0);
    vec3 v3b = vec3(f * 4.0, v2);
    vec4 v4a = vec4(v3a, f * 5.0);
    vec4 v4b = vec4(v2, v2 * 2.0);
    vec4 v4c = vec4(f);
    // Chain constructors
    vec4 result = v4a + v4b + v4c;
    fragColor = result * 0.05;
}

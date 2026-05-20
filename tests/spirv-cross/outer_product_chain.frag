#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 a = vec2(1.0, 2.0);
    vec2 b = vec2(3.0, 4.0);
    vec3 c = vec3(0.5, 1.0, 1.5);
    vec3 d = vec3(2.0, 1.0, 0.5);
    mat2 m2 = outerProduct(a, b);
    mat3 m3 = outerProduct(c, d);
    vec2 r1 = m2 * a;
    vec3 r2 = m3 * c;
    fragColor = vec4(r1, r2.xy);
}

#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 c = cross(a, b);
    float d = dot(c, a);
    float len = length(c);
    vec3 n = normalize(a + b + c);
    float dist = distance(a, b);
    fragColor = vec4(d, len, dist, 1.0);
}

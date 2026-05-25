// Tests: cross product and dot product interaction
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 c = cross(a, b);
    float d = dot(c, a);
    float e = dot(c, b);
    vec3 result = c * 0.5 + vec3(d, e, 0.0);
    fragColor = vec4(result, 1.0);
}

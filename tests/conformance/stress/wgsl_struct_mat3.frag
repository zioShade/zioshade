// Tests: struct with mat3 member
#version 450
layout(location = 0) out vec4 fragColor;

struct Transform3D {
    mat3 rotation;
    vec3 translation;
};

vec3 applyTransform(Transform3D t, vec3 p) {
    return t.rotation * p + t.translation;
}

void main() {
    Transform3D t;
    t.rotation = mat3(1.0);
    t.translation = vec3(0.5, 0.5, 0.0);
    vec3 p = vec3(0.3, 0.4, 0.0);
    vec3 result = applyTransform(t, p);
    fragColor = vec4(result, 1.0);
}

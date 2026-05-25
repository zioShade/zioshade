// Tests: function with struct return and struct parameter
#version 450
layout(location = 0) out vec4 fragColor;

struct Transform {
    mat3 rotation;
    vec3 offset;
};

Transform makeTransform(float angle, vec3 offset) {
    float c = cos(angle);
    float s = sin(angle);
    Transform t;
    t.rotation = mat3(
        c, -s, 0.0,
        s,  c, 0.0,
        0.0, 0.0, 1.0
    );
    t.offset = offset;
    return t;
}

vec3 applyTransform(Transform t, vec3 p) {
    return t.rotation * p + t.offset;
}

void main() {
    Transform t = makeTransform(1.57, vec3(1.0, 0.0, 0.0));
    vec3 p = vec3(0.5, 0.5, 0.0);
    vec3 result = applyTransform(t, p);
    fragColor = vec4(clamp(result, 0.0, 1.0), 1.0);
}

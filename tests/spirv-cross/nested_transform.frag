#version 450

// Test: complex struct with nested access patterns
struct Transform {
    mat3 matrix;
    vec3 translation;
};

struct Object {
    Transform transform;
    vec3 color;
    float opacity;
};

vec3 transformPoint(Transform t, vec3 p) {
    return t.matrix * p + t.translation;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    Object obj;
    obj.transform.matrix = mat3(1.0);
    obj.transform.translation = vec3(uv, 0.0);
    obj.color = vec3(0.8, 0.5, 0.3);
    obj.opacity = 0.9;

    vec3 p = transformPoint(obj.transform, vec3(uv, 0.5));
    vec3 col = obj.color * p.z * obj.opacity;

    gl_FragColor = vec4(clamp(col, 0.0, 1.0), obj.opacity);
}

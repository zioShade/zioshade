// Test: std140/std430 nested-struct member offset (#181)
// A member that follows a nested struct (or array-of-struct) must advance past
// the struct's real size. spirv-val/round-trip coverage; offsets themselves are
// pinned by tests/std140_nested_offset_tests.zig against the glslang oracle.
#version 450

struct Light {
    vec4 pos;
    float intensity;
};

struct Material {
    vec4 albedo;
    Light l;
};

layout(std140, binding = 0) uniform Scene {
    Material mat;       // nested struct
    Light lights[3];    // array-of-struct
    mat4 mvp;           // follows nested data — must not overlap
    float exposure;     // trailing scalar after a matrix
};

layout(location = 0) out vec4 FragColor;

void main() {
    vec4 c = mat.albedo * mat.l.intensity;
    for (int i = 0; i < 3; i++) {
        c += lights[i].pos * lights[i].intensity;
    }
    FragColor = (mvp * c) * exposure;
}

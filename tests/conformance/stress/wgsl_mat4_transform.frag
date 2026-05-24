#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Mat4 transform
    mat4 m = mat4(
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        uv.x, uv.y, 0.0, 1.0
    );
    vec4 pos = vec4(uv, 0.0, 1.0);
    vec4 transformed = m * pos;
    mat4 t = transpose(m);
    float d = determinant(m);
    vec4 result = transformed * d;
    fragColor = vec4(result.xy, t[3].xy);
}

#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;
void main() {
    // Test mat2/mat4 diagonal constructors
    mat2 m2 = mat2(2.0);
    mat4 m4 = mat4(1.0);
    vec2 c2 = m2[0];
    vec4 c4 = m4[3];
    float d = c2.x + c4.w;
    fragColor = vec4(d * uv.x, c2.y, c4.z, 1.0);
}

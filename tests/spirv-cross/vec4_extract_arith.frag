#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec3 v = vec3(0.3, 0.5, 0.7);
    vec4 a = vec4(v);
    // These component extracts + arithmetic MUST NOT be folded incorrectly
    float x = a.x * 0.5;
    float y = a.y * 0.5;
    float z = a.z * 0.5;
    float w = a.w; // should be 1.0 from auto-fill
    fragColor = vec4(x, y, z, w);
}

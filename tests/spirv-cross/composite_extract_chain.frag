#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec4 a = vec4(1.0, 2.0, 3.0, 4.0);
    vec4 b = vec4(5.0, 6.0, 7.0, 8.0);
    // Composite extract and construct chain
    float x = a.x;
    float y = b.y;
    float z = a.z + b.w;
    vec2 v1 = vec2(x, y);
    vec3 v2 = vec3(v1, z);
    vec4 v3 = vec4(v2, a.w * b.x);
    // Nested extract
    float final_val = v3.z + v3.w;
    fragColor = vec4(final_val * 0.1);
}

#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test vec3 from integer literals
    vec3 a = vec3(1, 2, 3);
    vec3 b = vec3(4, 5, 6);

    // Test vector negate and arithmetic
    vec3 c = -a + b;

    // Test vector swizzle in expression
    float d = a.x + a.y * a.z;

    // Test float mod
    float e = mod(uv.x * 5.0, 2.0);

    fragColor = vec4(c.x / 6.0, d / 7.0, e / 2.0, 1.0);
}

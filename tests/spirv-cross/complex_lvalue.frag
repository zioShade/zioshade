#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec4 c = vec4(0.0);
    // Complex lvalue assignments
    c.x = 1.0;
    c.yz = vec2(2.0, 3.0);
    c.w = 4.0;
    // Swizzle write
    c.zw = c.xy;
    // Compound assignment
    c.x += 0.5;
    c.y *= 2.0;
    c.z -= 0.1;
    // Nested swizzle access
    vec2 v = c.xy;
    c.zw = v * 0.5;
    fragColor = c;
}

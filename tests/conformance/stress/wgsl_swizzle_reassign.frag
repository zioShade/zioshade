// Tests: vec4 swizzle reassignment
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
    v.xz = v.yw;
    v.yw = vec2(0.5, 0.5);
    fragColor = v;
}

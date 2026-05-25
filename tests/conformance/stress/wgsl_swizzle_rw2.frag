// Tests: vec4 swizzle write and read
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
    v.xy = v.zw;
    v.z = v.x + v.y;
    fragColor = v;
}

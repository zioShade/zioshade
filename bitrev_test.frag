#version 450
flat layout(location = 0) in uint val;
layout(location = 0) out vec4 fragColor;
void main() {
    uint r = bitfieldReverse(val);
    fragColor = vec4(float(r));
}

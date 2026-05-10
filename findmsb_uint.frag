#version 450
flat layout(location = 0) in uint val;
layout(location = 0) out vec4 fragColor;
void main() {
    int msb = findMSB(val);
    fragColor = vec4(float(msb));
}

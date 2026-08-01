#version 450
// Exercises OpBitCount (the GLSL bitCount builtin; distinct from bit_count.frag's
// manual shift loop). uint + int variants.
layout(location = 0) out vec4 FragColor;
void main() {
    uint xu = uint(gl_FragCoord.x) ^ uint(gl_FragCoord.y);
    int cu = bitCount(xu);
    int ci = bitCount(int(xu));
    FragColor = vec4(float(cu), float(ci), float(xu & 0xFFu), 1.0);
}

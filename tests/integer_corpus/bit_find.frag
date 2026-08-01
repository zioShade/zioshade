#version 450
// Exercises OpFindILsb/OpFindSMsb/OpFindULsb/OpFindUMsb (GLSL findLSB/findMSB).
// UB-free: findLSB/findMSB of 0 are defined (-1).
layout(location = 0) out vec4 FragColor;
void main() {
    int xi = int(gl_FragCoord.x) ^ int(gl_FragCoord.y);
    uint xu = uint(gl_FragCoord.x);
    int lsb = findLSB(xi);
    int msb = findMSB(xi);
    int ulsb = findLSB(xu);
    FragColor = vec4(float(lsb), float(msb), float(ulsb), 1.0);
}

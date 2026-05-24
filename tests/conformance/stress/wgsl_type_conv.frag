// Tests: explicit type conversions
#version 450
uniform float u_f;
uniform int u_i;
uniform uint u_u;

void main() {
    int fi = int(u_f);
    float iv = float(u_i);
    uint fu = uint(u_f);
    float uf = float(u_u);
    int ui = int(u_u);
    gl_FragColor = vec4(float(fi) + iv + uf, float(ui), 0.0, 1.0);
}

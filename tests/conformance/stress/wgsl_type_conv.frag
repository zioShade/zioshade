// Tests: type conversion chain (int → float → uint)
#version 450
uniform int u_val;

void main() {
    float f = float(u_val) / 100.0;
    uint u = uint(f * 100.0);
    float r = float(u) / 1000.0;
    gl_FragColor = vec4(r, f, 0.0, 1.0);
}

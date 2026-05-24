// Tests: negate and not operators
#version 450
uniform float u_val;
uniform int u_int;

void main() {
    float neg = -u_val;
    int negi = -u_int;
    bool b = u_val > 0.5;
    bool nb = !b;
    float result = nb ? neg : float(negi);
    gl_FragColor = vec4(result, 0.0, 0.0, 1.0);
}

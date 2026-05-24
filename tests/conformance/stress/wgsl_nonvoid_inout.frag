// Tests: non-void function with inout parameter
precision mediump float;
uniform float u_val;

float modify_and_return(inout float x, float delta) {
    float orig = x;
    x = x + delta;
    return orig;
}

void main() {
    float a = u_val;
    float orig = modify_and_return(a, 1.0);
    gl_FragColor = vec4(orig, a, 0.0, 1.0);
}

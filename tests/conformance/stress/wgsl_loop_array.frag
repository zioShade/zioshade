// Tests: for loop with early return
#version 450
uniform float u_vals[4];

void main() {
    float result = 0.0;
    for (int i = 0; i < 4; i++) {
        if (u_vals[i] > 0.9) {
            result = u_vals[i];
            break;
        }
        result += u_vals[i];
    }
    gl_FragColor = vec4(result, 0.0, 0.0, 1.0);
}

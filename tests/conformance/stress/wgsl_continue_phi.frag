// Tests: continue with induction variable update
// The continue must not skip the phi update (j++)
#version 450
uniform float u_val;

void main() {
    float sum = 0.0;
    for (int j = 0; j < 10; j++) {
        if (j == 3) continue;
        sum += float(j);
    }
    // Expected: sum = 0+1+2+4+5+6+7+8+9 = 42
    gl_FragColor = vec4(sum / 100.0, 0.0, 0.0, 1.0);
}

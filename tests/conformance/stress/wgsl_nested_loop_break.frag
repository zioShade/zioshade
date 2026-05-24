// Tests: nested loops with break/continue
#version 450
uniform float u_time;

void main() {
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 5; j++) {
            if (i == j) continue;
            if (i + j > 6) break;
            sum += float(i * 5 + j) * u_time * 0.01;
        }
    }
    float result = fract(sum);
    gl_FragColor = vec4(result, result, result, 1.0);
}

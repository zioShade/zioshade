// Tests: nested function calls with array parameters (by value and inout)
precision mediump float;
uniform vec2 u_resolution;

void initArray(inout float arr[4], float base) {
    for (int i = 0; i < 4; i++) {
        arr[i] = base + float(i) * 0.25;
    }
}

float sumArray(float arr[4]) {
    float s = 0.0;
    for (int i = 0; i < 4; i++) {
        s += arr[i];
    }
    return s;
}

float process(float base) {
    float data[4];
    initArray(data, base);
    return sumArray(data) * 0.25;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float v = process(uv.x);
    gl_FragColor = vec4(vec3(fract(v)), 1.0);
}

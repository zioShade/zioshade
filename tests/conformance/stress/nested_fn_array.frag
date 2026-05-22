// Tests: nested function calls where inner modifies a local array
precision mediump float;
uniform vec2 u_resolution;

void fillGradient(float arr[4], float base) {
    for (int i = 0; i < 4; i++) {
        arr[i] = base + float(i) * 0.1;
    }
}

float process(float vals[4], float x) {
    fillGradient(vals, x);
    int idx = int(x * 3.999);
    idx = clamp(idx, 0, 3);
    return vals[idx];
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float data[4];
    float v = process(data, uv.x);
    
    gl_FragColor = vec4(vec3(fract(v)), 1.0);
}

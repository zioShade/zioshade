// Tests: function with multiple return paths returning array element
precision mediump float;
uniform vec2 u_resolution;

float pick(float data[8], int mode, float selector) {
    if (mode == 0) {
        int idx = int(selector * 7.999);
        idx = clamp(idx, 0, 7);
        return data[idx];
    } else if (mode == 1) {
        return data[0] + data[7];
    } else {
        float sum = 0.0;
        for (int i = 0; i < 8; i++) {
            sum += data[i];
        }
        return sum * 0.125;
    }
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float data[8];
    for (int i = 0; i < 8; i++) {
        data[i] = hash(float(i) * 0.1 + uv.x);
    }
    
    int mode = int(uv.x * 2.999);
    mode = clamp(mode, 0, 2);
    float v = pick(data, mode, uv.y);
    
    gl_FragColor = vec4(vec3(fract(v)), 1.0);
}

float hash(float n) {
    return fract(sin(n) * 43758.5453);
}

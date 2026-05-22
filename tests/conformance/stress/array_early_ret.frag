// Tests: early return from function with multiple paths
precision mediump float;
uniform vec2 u_resolution;

float findThreshold(float values[6], float target) {
    for (int i = 0; i < 6; i++) {
        if (values[i] > target) {
            return values[i];
        }
    }
    return target;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float data[6];
    data[0] = 0.1;
    data[1] = 0.3;
    data[2] = 0.5;
    data[3] = 0.7;
    data[4] = 0.9;
    data[5] = 1.1;
    
    float v = findThreshold(data, uv.x);
    
    gl_FragColor = vec4(vec3(fract(v)), 1.0);
}

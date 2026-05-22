// Tests: function returning array element selected by dynamic index
precision mediump float;
uniform vec2 u_resolution;

float selectValue(float vals[5], int idx) {
    return vals[idx];
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float data[5];
    data[0] = 0.1;
    data[1] = 0.3;
    data[2] = 0.5;
    data[3] = 0.7;
    data[4] = 0.9;
    
    int idx = int(uv.x * 4.999);
    idx = clamp(idx, 0, 4);
    float v = selectValue(data, idx);
    
    gl_FragColor = vec4(vec3(v), 1.0);
}

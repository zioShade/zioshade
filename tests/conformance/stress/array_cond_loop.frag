// Tests: array element modification inside conditional inside loop
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float buf[4];
    buf[0] = 0.1;
    buf[1] = 0.2;
    buf[2] = 0.3;
    buf[3] = 0.4;
    
    for (int i = 0; i < 4; i++) {
        if (uv.x > float(i) * 0.25) {
            buf[i] += uv.y * 0.5;
        }
    }
    
    int idx = int(uv.x * 3.999);
    idx = clamp(idx, 0, 3);
    
    float r = buf[idx];
    float g = buf[(idx + 1) % 4];
    
    gl_FragColor = vec4(fract(r), fract(g), 0.5, 1.0);
}

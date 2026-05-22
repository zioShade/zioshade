// Tests: switch statement with fallthrough-like patterns
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    int mode = int(uv.x * 4.0);
    float val = 0.0;
    
    switch (mode) {
        case 0: val = 0.25; break;
        case 1: val = 0.50; break;
        case 2: val = 0.75; break;
        case 3: val = 1.00; break;
        default: val = 0.0; break;
    }
    
    vec3 col = vec3(val, val * 0.5, 1.0 - val);
    gl_FragColor = vec4(col, 1.0);
}

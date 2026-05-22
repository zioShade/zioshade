// Tests: nested do-while loops with break
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float val = 0.0;
    int outer = 0;
    
    do {
        int inner = 0;
        float x = uv.x + float(outer) * 0.1;
        do {
            val += x * 0.01;
            inner++;
            if (val > 0.8) break;
        } while (inner < 3);
        outer++;
        if (val > 0.9) break;
    } while (outer < 5);
    
    gl_FragColor = vec4(fract(val), float(outer) * 0.2, 0.5, 1.0);
}

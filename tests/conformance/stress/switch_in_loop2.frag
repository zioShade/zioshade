// Tests: switch inside loop with variable accumulation across iterations
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float total = 0.0;
    for (int i = 0; i < 4; i++) {
        float x = uv.x + float(i) * 0.25;
        int mode = int(x * 3.0) % 3;
        
        float val;
        switch (mode) {
            case 0: val = x * x; break;
            case 1: val = sin(x * 6.28); break;
            case 2: val = fract(x * 5.0); break;
            default: val = 0.0; break;
        }
        
        total += val;
    }
    
    vec3 col = vec3(fract(total), fract(total * 0.5), fract(total * 0.3));
    gl_FragColor = vec4(col, 1.0);
}

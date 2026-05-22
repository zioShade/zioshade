// Tests: nested loop with break from inner loop and continue from outer
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float sum = 0.0;
    
    for (int j = 0; j < 6; j++) {
        float fj = float(j);
        
        if (fj * uv.y > 2.0) continue;
        
        for (int i = 0; i < 10; i++) {
            float fi = float(i);
            float val = sin(fi * 0.7 + fj * 1.3) * 0.5 + 0.5;
            sum += val * 0.01;
            
            if (sum > 0.5) break;
        }
    }
    
    gl_FragColor = vec4(vec3(fract(sum)), 1.0);
}

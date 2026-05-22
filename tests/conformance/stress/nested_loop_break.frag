// Tests: nested for loops with break/continue in different positions
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec3 col = vec3(0.0);
    
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 8; i++) {
            float fi = float(i);
            float fj = float(j);
            
            if (fi + fj * 8.0 > uv.x * 40.0) {
                break;
            }
            
            col.r += 0.01;
            
            if (fi < 2.0) {
                continue;
            }
            
            col.g += 0.02;
            col.b += 0.005;
        }
    }
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

// Tests: nested for loops with break and continue
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float sum = 0.0;
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 8; j++) {
            float x = float(i) / 8.0;
            float y = float(j) / 8.0;
            float d = length(vec2(x, y) - uv);
            if (d < 0.01) {
                sum += 1.0;
                break;
            }
            if (d > 0.5) continue;
            sum += 0.01 / (d + 0.01);
        }
    }
    
    vec3 col = vec3(fract(sum * 0.1), fract(sum * 0.05), fract(sum * 0.02));
    gl_FragColor = vec4(col, 1.0);
}

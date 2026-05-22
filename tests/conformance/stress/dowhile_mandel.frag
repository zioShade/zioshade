// Tests: do-while loop with complex exit condition and early break
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float x = uv.x * 3.0 - 1.5;
    float y = uv.y * 3.0 - 1.5;
    int iter = 0;
    float zx = 0.0;
    float zy = 0.0;
    
    do {
        float tmp = zx * zx - zy * zy + x;
        zy = 2.0 * zx * zy + y;
        zx = tmp;
        iter++;
        
        if (zx * zx + zy * zy > 100.0) break;
    } while (iter < 50 && zx * zx + zy * zy < 100.0);
    
    float t = float(iter) / 50.0;
    vec3 col = vec3(t, sqrt(t), t * t);
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

// Tests: for loop with complex init expression and multiple update assignments
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float x = uv.x;
    float y = uv.y;
    float best = 999.0;
    int bestIdx = 0;
    
    for (int i = 0; i < 8; i = i + 1) {
        float cx = float(i) * 0.125 + 0.0625;
        float cy = sin(cx * 6.28) * 0.3 + 0.5;
        float d = length(vec2(x, y) - vec2(cx, cy));
        
        if (d < best) {
            best = d;
            bestIdx = i;
        }
    }
    
    float r = float(bestIdx) / 8.0;
    float g = best;
    float b = 1.0 - best;
    
    gl_FragColor = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0);
}

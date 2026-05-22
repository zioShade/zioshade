// Tests: discard inside nested loop with conditional
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec3 col = vec3(0.0);
    
    for (int i = 0; i < 5; i++) {
        float fi = float(i) * 0.2;
        float d = length(uv - vec2(fi, 0.5));
        
        if (d < 0.05) {
            // Discard in a branch inside a loop
            if (uv.y < 0.1) {
                discard;
            }
            col += vec3(1.0 - d * 10.0, 0.5, fi);
        }
    }
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

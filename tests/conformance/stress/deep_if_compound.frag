// Tests: 3-level nested if/else with compound assignments on same variable
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float val = 0.5;
    
    if (uv.x > 0.33) {
        val += 0.2;
        if (uv.x > 0.66) {
            val *= 1.5;
        } else {
            val *= 0.8;
        }
    } else {
        val -= 0.1;
        if (uv.y > 0.5) {
            val += 0.3;
        } else {
            val += 0.05;
        }
    }
    
    // Post-conditional use
    val += uv.y * 0.2;
    
    gl_FragColor = vec4(clamp(vec3(val, val * 0.7, val * 0.3), 0.0, 1.0), 1.0);
}

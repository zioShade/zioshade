// Tests: constant condition in nested if (foldConstBranches)
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec3 col = vec3(0.0);
    
    // Constant condition — should be folded
    if (true) {
        col.r = uv.x;
    }
    
    if (false) {
        col.g = 0.0; // dead code
    } else {
        col.g = uv.y;
    }
    
    // Nested constant conditions
    if (1 > 0) {
        if (2 < 1) {
            col.b = 0.0; // dead
        } else {
            col.b = uv.x + uv.y;
        }
    }
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

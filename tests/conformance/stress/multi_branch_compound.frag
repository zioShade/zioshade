// Tests: vec4 component assignment with multiple branches and compound assignment
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 col = vec4(0.2, 0.3, 0.4, 1.0);
    
    // Component assignments
    col.x = uv.x;
    col.y += 0.1;
    
    // Multiple branches modifying different components
    if (uv.x > 0.25) {
        col.z = uv.y;
    }
    if (uv.x > 0.5) {
        col.w = 0.8;
        col.x *= 1.5;
    }
    if (uv.x > 0.75) {
        col.y = 0.9;
        col.z += 0.2;
    }
    
    gl_FragColor = clamp(col, 0.0, 1.0);
}

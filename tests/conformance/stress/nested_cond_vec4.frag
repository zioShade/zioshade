// Tests: complex nested conditional with vec4 assignment
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 col = vec4(0.5);
    
    // 4-level nested conditional modifying different components
    if (uv.x > 0.25) {
        col.r = uv.x;
        if (uv.y > 0.5) {
            col.g = uv.y * 2.0;
        } else {
            col.g = 0.3;
        }
    } else {
        col.r = 0.2;
        if (uv.x > 0.125) {
            col.b = uv.y;
        } else {
            col.b = 0.7;
        }
    }
    
    // Post-conditional compound assignment
    col.rgb *= 0.9 + 0.1 * sin(uv.x * 6.28);
    
    gl_FragColor = clamp(col, 0.0, 1.0);
}

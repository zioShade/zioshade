// Tests: vec4 construction + component assignment + conditional
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 col = vec4(0.0);
    col.x = uv.x;
    col.y = uv.y;
    col.z = 0.5;
    col.w = 1.0;
    
    if (uv.x > 0.5) {
        col.x *= 2.0;
        col.y += 0.2;
    }
    
    gl_FragColor = clamp(col, 0.0, 1.0);
}

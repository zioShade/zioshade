// Tests: mat4 column assignment in a loop
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    mat4 m = mat4(1.0);
    
    for (int i = 0; i < 3; i++) {
        float angle = float(i) * 0.5 + uv.x * 3.0;
        vec4 col = vec4(cos(angle), sin(angle), 0.0, 0.0);
        m[i] = col;
    }
    
    vec4 p = m * vec4(uv, 0.0, 1.0);
    
    gl_FragColor = vec4(fract(p.x), fract(p.y), fract(p.z), 1.0);
}

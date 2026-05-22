// Tests: dFdx/dFdy on computed values inside conditional
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float x = uv.x * 10.0;
    float y = uv.y * 10.0;
    
    vec3 col;
    if (uv.x > 0.5) {
        col = vec3(dFdx(x), dFdy(y), 0.5);
    } else {
        col = vec3(dFdx(y), dFdy(x), 0.3);
    }
    
    gl_FragColor = vec4(abs(col), 1.0);
}

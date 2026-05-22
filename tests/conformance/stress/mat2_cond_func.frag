// Tests: mat2 constructed from function return, used in conditional
precision mediump float;
uniform vec2 u_resolution;

mat2 makeRotation(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat2(c, -s, s, c);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    mat2 m;
    if (uv.x > 0.5) {
        m = makeRotation(uv.x * 3.14159);
    } else {
        m = makeRotation(uv.y * 1.5708);
    }
    
    vec2 p = m * (uv - 0.5);
    
    float r = fract(p.x + 0.5);
    float g = fract(p.y + 0.5);
    
    gl_FragColor = vec4(r, g, 0.5, 1.0);
}

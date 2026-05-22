// Tests: matrix by-value parameter with column extraction
precision mediump float;
uniform vec2 u_resolution;

vec2 transform(mat2 m, vec2 v) {
    // Access columns of by-value matrix parameter
    return m * v;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    mat2 rot = mat2(cos(uv.x), -sin(uv.x),
                    sin(uv.x),  cos(uv.x));
    
    vec2 result = transform(rot, uv);
    
    gl_FragColor = vec4(fract(result), 0.5, 1.0);
}

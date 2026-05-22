// Tests: matrix passed by value with dynamic column index
precision mediump float;
uniform vec2 u_resolution;

vec3 getCol(mat3 m, int col) {
    return m[col]; // by-value matrix, dynamic column index
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    mat3 m = mat3(
        1.0, 0.0, 0.0,
        0.0, cos(uv.x), sin(uv.x),
        0.0, -sin(uv.x), cos(uv.x)
    );
    
    int col = int(uv.y * 2.999);
    col = clamp(col, 0, 2);
    vec3 c = getCol(m, col);
    
    gl_FragColor = vec4(abs(c), 1.0);
}

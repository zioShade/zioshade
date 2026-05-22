// Tests: matrix multiplication with conditional matrix selection
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    mat2 rot = mat2(cos(uv.x), -sin(uv.x),
                    sin(uv.x),  cos(uv.x));
    
    mat2 scale;
    if (uv.y > 0.5) {
        scale = mat2(2.0, 0.0, 0.0, 2.0);
    } else {
        scale = mat2(0.5, 0.0, 0.0, 0.5);
    }
    
    mat2 combined = scale * rot;
    vec2 transformed = combined * uv;
    
    gl_FragColor = vec4(fract(transformed.x), fract(transformed.y), 0.5, 1.0);
}

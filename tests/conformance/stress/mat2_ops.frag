// Tests: mat2 construction, multiplication, and element access
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float angle = uv.x * 3.14159;
    float c = cos(angle);
    float s = sin(angle);
    
    mat2 rot = mat2(c, -s, s, c);
    mat2 scale = mat2(2.0, 0.0, 0.0, 2.0);
    mat2 m = rot * scale;
    
    vec2 p = m * (uv - 0.5);
    
    float r = fract(p.x * 2.0 + 0.5);
    float g = fract(p.y * 2.0 + 0.5);
    float b = fract(r + g);
    
    gl_FragColor = vec4(r, g, b, 1.0);
}

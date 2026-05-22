// Tests: vec2 arithmetic with scalar promotion
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // scalar * vector promotion
    vec2 a = 2.0 * uv;           // scalar * vec2
    vec2 b = uv + 0.5;           // vec2 + scalar
    vec2 c = uv * 3.0 - 0.5;     // vec2 * scalar - scalar
    vec2 d = 1.0 / (uv + 0.001); // scalar / vec2
    
    vec3 col = vec3(a.x, b.y, c.x + d.y);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

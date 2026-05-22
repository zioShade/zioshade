// Tests: nested ternary with different vector sizes
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Nested ternary returning different types (float vs vec2 in ternary)
    float r = uv.x > 0.5 ? (uv.y > 0.5 ? uv.x : 1.0 - uv.x) : 0.5;
    float g = uv.x > 0.3 ? uv.y : (uv.y > 0.7 ? 1.0 : 0.0);
    float b = uv.x + uv.y > 1.0 ? sin(uv.x * 3.14) : cos(uv.y * 3.14);
    
    gl_FragColor = vec4(r, g, b, 1.0);
}

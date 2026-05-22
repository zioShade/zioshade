// Tests: conditional nested ternary with vector construction
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Chained ternary selecting vector components
    float r = uv.x > 0.5 ? uv.x : 1.0 - uv.x;
    float g = uv.y > 0.5 ? uv.y * 2.0 : uv.y * 0.5;
    float b = (r + g) > 1.0 ? 0.3 : 0.7;
    float a = r > g ? 0.9 : 0.1;
    
    // Nested ternary in expression
    float extra = uv.x > 0.3 ? (uv.y > 0.6 ? 0.2 : 0.4) : 0.8;
    
    vec4 col = vec4(r, g + extra * 0.1, b, a);
    gl_FragColor = clamp(col, 0.0, 1.0);
}

// Tests: mat4 construction and column access with dynamic index
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Build mat4 column by column
    vec4 c0 = vec4(1.0, 0.0, 0.0, 0.0);
    vec4 c1 = vec4(0.0, cos(uv.x), sin(uv.x), 0.0);
    vec4 c2 = vec4(0.0, -sin(uv.x), cos(uv.x), 0.0);
    vec4 c3 = vec4(uv.x * 0.5, uv.y * 0.5, 0.0, 1.0);
    
    mat4 m = mat4(c0, c1, c2, c3);
    
    // Access column
    vec4 col0 = m[0];
    vec4 col3 = m[3];
    
    vec4 p = m * vec4(uv, 0.0, 1.0);
    
    float r = fract(p.x);
    float g = fract(p.y);
    float b = fract(col0.x + col3.w);
    
    gl_FragColor = vec4(r, g, b, 1.0);
}

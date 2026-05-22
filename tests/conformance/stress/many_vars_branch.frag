// Tests: many variables in same scope with interleaved stores and loads
// Stress tests SSA construction and variable tracking
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float a = uv.x;
    float b = uv.y;
    float c = a + b;
    float d = a * b;
    float e = c - d;
    float f = e * 0.5;
    float g = a + d;
    float h = b + e;
    
    if (uv.x > 0.5) {
        a = f;
        c = g;
        e = h;
    } else {
        b = d;
        d = f;
        f = g;
    }
    
    float result = a + b + c + d + e + f + g + h;
    vec3 col = vec3(fract(result), fract(result * 0.3), fract(result * 0.7));
    gl_FragColor = vec4(col, 1.0);
}

// Tests: deeply nested function calls in vector construction
// This pattern stresses the inliner and SSA construction
precision mediump float;
uniform vec2 u_resolution;

float f1(float x) { return x + 0.1; }
float f2(float x) { return f1(x) * 2.0; }
float f3(float x) { return f2(x) - 0.5; }
float f4(float x) { return f3(f2(x)); }

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 col = vec4(
        f4(uv.x),
        f3(uv.y),
        f2(f1(uv.x + uv.y)),
        1.0
    );
    
    gl_FragColor = clamp(col, 0.0, 1.0);
}

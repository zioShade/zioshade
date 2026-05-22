// Tests: struct-return function called conditionally with chained calls
// Exercises: branchMergePhi with struct variables that have AccessChains
precision mediump float;
uniform vec2 u_resolution;

struct State {
    float x;
    float y;
    int step;
};

State advance(State s, float dx, float dy) {
    s.x += dx;
    s.y += dy;
    s.step += 1;
    return s;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    State s;
    s.x = uv.x;
    s.y = uv.y;
    s.step = 0;
    
    s = advance(s, 0.1, 0.0);
    s = advance(s, 0.0, 0.1);
    s = advance(s, -0.05, 0.05);
    
    if (uv.x > 0.5) {
        s = advance(s, -0.2, 0.0);
    }
    
    vec3 col = vec3(fract(s.x), fract(s.y), float(s.step) * 0.1);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

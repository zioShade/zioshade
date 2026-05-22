// Tests: struct variable modified through conditional function calls
precision mediump float;
uniform vec2 u_resolution;

struct State {
    float value;
    float delta;
};

State advance(State s) {
    State next;
    next.value = s.value + s.delta;
    next.delta = s.delta * 0.95;
    return next;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    State s;
    s.value = 0.0;
    s.delta = uv.x;
    
    // Conditional chain — struct modified in different branches
    if (uv.y > 0.5) {
        s = advance(s);
        s = advance(s);
    } else {
        s = advance(s);
    }
    
    // Use result after conditional
    float r = s.value;
    float g = s.delta;
    
    gl_FragColor = vec4(fract(r), fract(g), 0.5, 1.0);
}

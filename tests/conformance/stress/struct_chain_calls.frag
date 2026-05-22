// Tests: multiple functions calling each other with struct params
precision mediump float;
uniform vec2 u_resolution;

struct State {
    float x;
    float y;
    float energy;
};

State advance(State s, float dt) {
    State next;
    next.x = s.x + cos(s.energy) * dt;
    next.y = s.y + sin(s.energy) * dt;
    next.energy = s.energy - dt * 0.1;
    return next;
}

State bounce(State s, float wall) {
    State next = s;
    if (next.x > wall) {
        next.x = wall - (next.x - wall);
        next.energy *= 0.9;
    }
    return next;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    State s;
    s.x = uv.x;
    s.y = uv.y;
    s.energy = 1.0;
    
    // Chain: advance then bounce
    s = advance(s, 0.1);
    s = bounce(s, 0.9);
    s = advance(s, 0.05);
    s = bounce(s, 0.95);
    
    gl_FragColor = vec4(fract(s.x), fract(s.y), s.energy, 1.0);
}

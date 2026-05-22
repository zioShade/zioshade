// Tests: struct-return function called 4 times with conditional 5th call
// Full chain of state advancement (the original state_chain pattern)
precision mediump float;
uniform vec2 u_resolution;

struct Particle {
    float x;
    float y;
    float vx;
    float vy;
};

Particle updateParticle(Particle p, float dt) {
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    return p;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Particle p;
    p.x = 0.5;
    p.y = 0.5;
    p.vx = 0.1;
    p.vy = 0.05;
    
    // Chain of updates
    p = updateParticle(p, uv.x);
    p = updateParticle(p, uv.y);
    p = updateParticle(p, 0.3);
    
    // Conditional update
    if (uv.x > 0.3 && uv.y > 0.3) {
        p = updateParticle(p, -0.2);
    }
    
    float d = length(vec2(p.x, p.y) - uv);
    vec3 col = vec3(fract(p.x), fract(p.y), d);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 310 es
precision highp float;
out vec4 fragColor;

struct Particle {
    vec2 pos;
    vec2 vel;
    float life;
};

Particle update(Particle p, float dt) {
    p.pos += p.vel * dt;
    p.life -= dt;
    return p;
}

void main() {
    Particle p;
    p.pos = gl_FragCoord.xy;
    p.vel = vec2(1.0, -0.5);
    p.life = 1.0;
    p = update(p, 0.016);
    p = update(p, 0.016);
    fragColor = vec4(p.pos * 0.005, p.life, 1.0);
}

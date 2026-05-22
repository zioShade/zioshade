#version 310 es
precision highp float;
out vec4 fragColor;

// Nested function with struct param modified via AccessChain
struct Particle {
    vec2 pos;
    vec2 vel;
    float life;
};

void updateParticle(inout Particle p, float dt) {
    p.pos = p.pos + p.vel * dt;
    p.life -= dt;
    if (p.life < 0.0) p.life = 0.0;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Particle p;
    p.pos = uv;
    p.vel = vec2(0.01, -0.02);
    p.life = 1.0;

    // Simulate 5 steps
    for (int i = 0; i < 5; i++) {
        updateParticle(p, 0.1);
    }

    float val = length(p.pos) * p.life;
    vec3 col = vec3(val, p.life, length(p.vel));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

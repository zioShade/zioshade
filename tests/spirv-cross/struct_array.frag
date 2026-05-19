#version 450

// Test: function with struct array
struct Particle {
    vec2 pos;
    vec2 vel;
    float life;
};

void updateParticle(inout Particle p, float dt) {
    p.pos = p.pos + p.vel * dt;
    p.life -= dt;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    Particle particles[3];
    particles[0].pos = vec2(0.2, 0.3);
    particles[0].vel = vec2(0.1, 0.05);
    particles[0].life = 1.0;
    particles[1].pos = vec2(0.5, 0.5);
    particles[1].vel = vec2(-0.05, 0.1);
    particles[1].life = 0.8;
    particles[2].pos = vec2(0.8, 0.7);
    particles[2].vel = vec2(0.03, -0.07);
    particles[2].life = 0.6;

    for (int i = 0; i < 3; i++) {
        updateParticle(particles[i], uv.x * 0.1);
    }

    // Color based on nearest particle
    float minD = 999.0;
    int nearest = 0;
    for (int i = 0; i < 3; i++) {
        float d = distance(uv, particles[i].pos);
        if (d < minD) {
            minD = d;
            nearest = i;
        }
    }

    vec3 col = vec3(
        particles[nearest].life,
        particles[nearest].pos.x,
        particles[nearest].pos.y
    );
    gl_FragColor = vec4(col, 1.0);
}

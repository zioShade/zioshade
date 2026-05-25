// Tests: conditional store to struct field
#version 450
layout(location = 0) out vec4 fragColor;

struct Particle {
    vec3 pos;
    vec3 vel;
    float life;
};

void main() {
    Particle p;
    p.pos = vec3(0.0);
    p.vel = vec3(1.0, 0.0, 0.0);
    p.life = 1.0;

    float dt = 0.016;
    p.pos += p.vel * dt;
    p.life -= dt;

    if (p.life < 0.5) {
        p.vel = vec3(0.0, -1.0, 0.0);
    }

    fragColor = vec4(clamp(p.pos, 0.0, 1.0), p.life);
}

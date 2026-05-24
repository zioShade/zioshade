// Tests: struct array with loop iteration
#version 450
uniform float u_time;

struct Particle {
    vec2 pos;
    vec2 vel;
    float life;
};

void main() {
    Particle p[3];
    p[0].pos = vec2(0.0, 0.0);
    p[0].vel = vec2(1.0, 0.5);
    p[0].life = 1.0;
    p[1].pos = vec2(0.5, 0.5);
    p[1].vel = vec2(-0.5, 0.3);
    p[1].life = 0.8;
    p[2].pos = vec2(0.2, 0.7);
    p[2].vel = vec2(0.3, -0.7);
    p[2].life = 0.5;

    vec2 center = vec2(0.0);
    for (int i = 0; i < 3; i++) {
        center += p[i].pos * p[i].life;
    }
    center /= 3.0;
    gl_FragColor = vec4(center, 0.0, 1.0);
}

// Tests: array of structs iteration
#version 450
uniform float u_time;

struct Particle {
    vec2 pos;
    vec2 vel;
    float life;
};

void main() {
    Particle parts[3];
    parts[0] = Particle(vec2(0.2, 0.3), vec2(0.1, 0.0), 1.0);
    parts[1] = Particle(vec2(0.5, 0.5), vec2(0.0, 0.1), 0.8);
    parts[2] = Particle(vec2(0.8, 0.7), vec2(-0.1, 0.0), 0.6);
    
    vec3 col = vec3(0.0);
    for (int i = 0; i < 3; i++) {
        float d = distance(parts[i].pos, vec2(u_time * 0.1));
        col += parts[i].life * vec3(1.0 / (1.0 + d));
    }
    gl_FragColor = vec4(col, 1.0);
}

#version 310 es
precision highp float;
out vec4 fragColor;

struct Particle {
    vec2 pos;
    vec2 vel;
    float life;
};

Particle spawn(vec2 p) {
    Particle pt;
    pt.pos = p;
    pt.vel = vec2(sin(p.y * 10.0), cos(p.x * 10.0));
    pt.life = 1.0;
    return pt;
}

Particle update(Particle pt, float dt) {
    pt.pos += pt.vel * dt;
    pt.life -= dt;
    return pt;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Multiple struct function calls
    Particle pt = spawn(uv);
    for (int i = 0; i < 3; i++) {
        pt = update(pt, 0.1);
        if (pt.life < 0.3) break;
    }

    float d = length(pt.pos - uv);
    vec3 col = vec3(pt.life * smoothstep(0.5, 0.0, d));

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

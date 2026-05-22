#version 310 es
precision highp float;
out vec4 fragColor;

struct Particle {
    vec2 pos;
    float life;
};

Particle makeParticle(vec2 p) {
    Particle pt;
    pt.pos = p;
    pt.life = 1.0;
    return pt;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Particle pt = makeParticle(uv);
    float d = length(pt.pos - uv);
    vec3 col = vec3(pt.life * smoothstep(0.5, 0.0, d));

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

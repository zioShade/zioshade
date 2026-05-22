// Tests: struct variable modified through chained function calls in conditional
precision mediump float;
uniform vec2 u_resolution;

struct Particle {
    vec2 pos;
    vec2 vel;
    float life;
};

Particle updateParticle(Particle p, float dt) {
    Particle next;
    next.pos = p.pos + p.vel * dt;
    next.vel = p.vel * vec2(0.99);
    next.life = p.life - dt;
    return next;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Particle p;
    p.pos = vec2(0.5);
    p.vel = vec2(uv.x * 0.5, uv.y * 0.3);
    p.life = 1.0;
    
    // Chain multiple updates
    p = updateParticle(p, 0.1);
    p = updateParticle(p, 0.1);
    p = updateParticle(p, 0.1);
    
    float d = length(uv - p.pos);
    float intensity = p.life / (d + 0.1);
    
    gl_FragColor = vec4(clamp(vec3(intensity, intensity * 0.5, d * 0.5), 0.0, 1.0), 1.0);
}

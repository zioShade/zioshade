// Tests: function with inout struct parameter
#version 450
layout(location = 0) out vec4 fragColor;

struct State {
    vec3 pos;
    float energy;
};

void updateState(inout State s, float dt) {
    s.pos = s.pos + vec3(1.0, 0.0, 0.0) * dt;
    s.energy -= dt * 0.1;
}

void main() {
    State s;
    s.pos = vec3(0.0);
    s.energy = 1.0;
    for (int i = 0; i < 5; i++) {
        updateState(s, 0.1);
    }
    fragColor = vec4(s.pos, s.energy);
}

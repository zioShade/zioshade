// Tests: complex array of structs with conditional access
#version 450
layout(location = 0) out vec4 fragColor;

struct Node {
    vec2 pos;
    float weight;
};

void main() {
    Node nodes[4];
    nodes[0].pos = vec2(0.0, 0.0);
    nodes[0].weight = 1.0;
    nodes[1].pos = vec2(1.0, 0.0);
    nodes[1].weight = 0.8;
    nodes[2].pos = vec2(0.0, 1.0);
    nodes[2].weight = 0.6;
    nodes[3].pos = vec2(1.0, 1.0);
    nodes[3].weight = 0.4;

    float total = 0.0;
    for (int i = 0; i < 4; i++) {
        if (nodes[i].weight > 0.5) {
            total += nodes[i].weight;
        }
    }
    fragColor = vec4(vec3(total / 4.0), 1.0);
}

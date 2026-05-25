// Tests: struct comparison and selection
#version 450
layout(location = 0) out vec4 fragColor;

struct Hit {
    float t;
    int id;
};

Hit minHit(Hit a, Hit b) {
    if (a.t < b.t) return a;
    return b;
}

void main() {
    Hit h1;
    h1.t = 0.5;
    h1.id = 0;
    Hit h2;
    h2.t = 0.3;
    h2.id = 1;
    Hit closest = minHit(h1, h2);
    vec3 color = (closest.id == 0) ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0);
    fragColor = vec4(color, closest.t);
}

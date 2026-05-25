// Tests: nested struct construction
#version 450
layout(location = 0) out vec4 fragColor;

struct Inner { float x; float y; };
struct Outer { Inner a; Inner b; };

float dist(Outer o) {
    float dx = o.a.x - o.b.x;
    float dy = o.a.y - o.b.y;
    return sqrt(dx * dx + dy * dy);
}

void main() {
    Inner p1 = Inner(0.2, 0.3);
    Inner p2 = Inner(0.7, 0.8);
    Outer o;
    o.a = p1;
    o.b = p2;
    float d = dist(o);
    fragColor = vec4(vec3(d), 1.0);
}

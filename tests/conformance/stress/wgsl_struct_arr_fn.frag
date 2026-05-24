#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test array of structs with function parameter passing
struct Point {
    vec2 pos;
    float size;
    float brightness;
};

float totalBrightness(Point pts[4]) {
    float total = 0.0;
    for (int i = 0; i < 4; i++) {
        total += pts[i].brightness;
    }
    return total;
}

void main() {
    Point pts[4];
    pts[0] = Point(vec2(0.0, 0.0), 1.0, 0.8);
    pts[1] = Point(vec2(0.5, 0.0), 1.5, 0.6);
    pts[2] = Point(vec2(0.0, 0.5), 1.0, 0.9);
    pts[3] = Point(vec2(0.5, 0.5), 2.0, 0.4);

    float total = totalBrightness(pts);
    float closest = 1.0 / (distance(uv, pts[0].pos) + 0.1);
    vec3 color = vec3(closest * 0.3, total * 0.1, uv.x * uv.y);
    fragColor = vec4(color, 1.0);
}

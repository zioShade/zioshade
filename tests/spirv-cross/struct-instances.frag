#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test multiple struct instances
    struct Point {
        float x;
        float y;
    };
    Point p1 = Point(uv.x, uv.y);
    Point p2 = Point(uv.y, uv.x);
    Point p3 = Point(p1.x + p2.x, p1.y + p2.y);
    fragColor = vec4(p3.x * 0.5, p3.y * 0.5, p1.x, 1.0);
}

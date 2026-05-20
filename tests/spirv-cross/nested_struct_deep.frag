#version 310 es
precision highp float;
out vec4 fragColor;

struct Inner {
    float a;
    vec2 b;
};

struct Middle {
    Inner data;
    float weight;
};

struct Outer {
    Middle items[2];
    vec3 color;
};

void main() {
    Outer o;
    o.items[0].data.a = 1.0;
    o.items[0].data.b = vec2(2.0, 3.0);
    o.items[0].weight = 0.5;
    o.items[1].data.a = 4.0;
    o.items[1].data.b = vec2(5.0, 6.0);
    o.items[1].weight = 0.7;
    o.color = vec3(0.3, 0.6, 0.9);
    vec3 col = o.color * o.items[0].weight;
    col += vec3(o.items[1].data.a * 0.1);
    fragColor = vec4(col, 1.0);
}

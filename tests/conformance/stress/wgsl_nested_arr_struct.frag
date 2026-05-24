#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test nested struct with array member
struct Inner {
    float values[3];
    float scale;
};

struct Outer {
    Inner data;
    vec3 offset;
};

void main() {
    Outer o;
    o.data.values[0] = 1.0;
    o.data.values[1] = 2.0;
    o.data.values[2] = 3.0;
    o.data.scale = 0.5;
    o.offset = vec3(0.1, 0.2, 0.3);

    float sum = o.data.values[0] + o.data.values[1] + o.data.values[2];
    float scaled = sum * o.data.scale;
    vec3 color = vec3(scaled) + o.offset;
    fragColor = vec4(color, 1.0);
}

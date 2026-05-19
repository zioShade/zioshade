#version 450

// Test: nested struct with arrays
struct Inner {
    float values[3];
};

struct Outer {
    Inner items[2];
    float scale;
};

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    Outer o;
    o.scale = 2.0;
    for (int i = 0; i < 3; i++) {
        o.items[0].values[i] = float(i) / 3.0;
        o.items[1].values[i] = uv.x * float(i + 1) / 4.0;
    }

    float r = o.items[0].values[int(uv.x * 2.99)];
    float g = o.items[1].values[int(uv.y * 2.99)];
    float b = o.scale * uv.y;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
}

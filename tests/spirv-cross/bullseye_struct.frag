#version 310 es
precision highp float;
out vec4 fragColor;

// Nested struct with array member + conditional modification
struct Ring {
    vec3 color;
    float radius;
};

struct Bullseye {
    Ring rings[3];
    vec2 center;
};

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Bullseye b;
    b.center = vec2(0.5);
    b.rings[0].color = vec3(1.0, 0.0, 0.0);
    b.rings[0].radius = 0.3;
    b.rings[1].color = vec3(1.0, 1.0, 0.0);
    b.rings[1].radius = 0.2;
    b.rings[2].color = vec3(1.0, 1.0, 1.0);
    b.rings[2].radius = 0.1;

    float d = length(uv - b.center);
    vec3 col = vec3(0.0);

    for (int i = 0; i < 3; i++) {
        if (d < b.rings[i].radius) {
            col = b.rings[i].color;
        }
    }

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

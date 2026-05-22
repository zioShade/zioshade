#version 310 es
precision highp float;
out vec4 fragColor;

// Nested function calls with struct returns in loop
struct Hit {
    float dist;
    int id;
};

Hit scene(vec2 p) {
    Hit h;
    h.dist = length(p - vec2(0.3)) - 0.2;
    h.id = 0;
    float d2 = length(p - vec2(0.7)) - 0.15;
    if (d2 < h.dist) {
        h.dist = d2;
        h.id = 1;
    }
    return h;
}

vec3 shade(Hit h, vec2 uv) {
    vec3 col = vec3(0.0);
    if (h.id == 0) {
        col = vec3(1.0, 0.3, 0.1) * (1.0 - h.dist);
    } else {
        col = vec3(0.1, 0.3, 1.0) * (1.0 - h.dist);
    }
    return col;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Hit h = scene(uv);
    vec3 col = shade(h, uv);

    // Use in a loop
    for (int i = 0; i < 3; i++) {
        float fi = float(i) * 0.1;
        Hit h2 = scene(uv + vec2(fi));
        if (h2.dist < h.dist) {
            col = shade(h2, uv + vec2(fi)) * 0.5;
        }
    }

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

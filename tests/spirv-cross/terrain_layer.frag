#version 310 es
precision highp float;
out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float fbm(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        val += amp * hash(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float heights[6];
    for (int i = 0; i < 6; i++) {
        heights[i] = fbm(uv * float(i + 1));
    }

    int layer = int(uv.y * 5.0);
    layer = clamp(layer, 0, 5);

    float h = heights[layer];
    vec3 col = vec3(0.0);

    switch (layer) {
        case 0: col = vec3(0.2, 0.5, 0.2); break;
        case 1: col = vec3(0.6, 0.5, 0.2); break;
        case 2: col = vec3(0.8, 0.6, 0.3); break;
        case 3: col = vec3(0.5, 0.4, 0.3); break;
        case 4: col = vec3(0.9, 0.9, 0.95); break;
        default: col = vec3(0.4, 0.4, 0.5); break;
    }

    if (h > 0.5) {
        col *= 1.0 + (h - 0.5);
    } else {
        col *= 0.5 + h;
    }

    if (layer > 0 && heights[layer - 1] > h) {
        col += 0.1;
    }
    if (layer < 5 && heights[layer + 1] > h) {
        col -= 0.05;
    }

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

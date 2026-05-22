#version 310 es
precision highp float;
out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Struct with array member + function returning struct element
    float values[4];
    for (int i = 0; i < 4; i++) {
        values[i] = hash(uv * float(i + 1));
    }

    // Sort partial (bubble sort 2 passes)
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < 3; i++) {
            if (values[i] > values[i + 1]) {
                float tmp = values[i];
                values[i] = values[i + 1];
                values[i + 1] = tmp;
            }
        }
    }

    // Median
    float median = values[2];
    float range = values[3] - values[0];

    vec3 col = mix(vec3(0.1, 0.2, 0.3), vec3(0.8, 0.6, 0.4), median);
    col += range * 0.5;

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

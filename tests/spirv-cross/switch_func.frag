#version 310 es
precision highp float;
out vec4 fragColor;

float helper(float x) {
    return sin(x) * 0.5;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float vals[4];
    for (int i = 0; i < 4; i++) {
        vals[i] = helper(uv.x * float(i + 1));
    }

    int c = int(uv.x * 3.0);
    c = clamp(c, 0, 3);

    float v = vals[c];
    vec3 col = vec3(0.0);

    switch (c) {
        case 0: col = vec3(1.0, 0.0, 0.0); break;
        case 1: col = vec3(0.0, 1.0, 0.0); break;
        case 2: col = vec3(0.0, 0.0, 1.0); break;
        case 3: col = vec3(1.0, 1.0, 0.0); break;
    }

    col *= v;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Array of vec3 with loop modification and dynamic read
    vec3 colors[4];
    colors[0] = vec3(1.0, 0.0, 0.0);
    colors[1] = vec3(0.0, 1.0, 0.0);
    colors[2] = vec3(0.0, 0.0, 1.0);
    colors[3] = vec3(1.0, 1.0, 0.0);

    for (int i = 0; i < 4; i++) {
        colors[i] *= sin(uv.x * 3.14159 + float(i));
    }

    int ci = int(uv.y * 3.0);
    ci = clamp(ci, 0, 3);
    vec3 col = colors[ci];

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

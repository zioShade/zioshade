#version 310 es
precision highp float;
out vec4 fragColor;

// Switch with runtime selector where cases have overlapping effects
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    vec3 col = vec3(0.0);
    int mode = int(uv.y * 5.0);
    mode = clamp(mode, 0, 4);

    float n = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5);

    switch (mode) {
        case 4: col += vec3(0.2, 0.0, 0.0); // fallthrough intentional
        case 3: col += vec3(0.0, 0.2, 0.0);
        case 2: col += vec3(0.0, 0.0, 0.2);
        case 1: col += vec3(0.1);
        case 0: col += vec3(n * 0.3);
    }

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

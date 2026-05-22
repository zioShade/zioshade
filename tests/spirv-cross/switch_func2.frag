#version 310 es
precision highp float;
out vec4 fragColor;

// Switch with function calls in cases (exercises inliner + switch interaction)
float noise(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

vec3 colorA(float t) {
    return mix(vec3(0.2, 0.5, 0.8), vec3(0.8, 0.2, 0.1), t);
}

vec3 colorB(float t) {
    return mix(vec3(0.1, 0.8, 0.3), vec3(0.9, 0.9, 0.1), t);
}

vec3 colorC(float t) {
    return mix(vec3(0.5, 0.1, 0.7), vec3(0.3, 0.6, 0.5), t);
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float n = noise(uv);
    int mode = int(uv.x * 3.0);
    mode = clamp(mode, 0, 2);

    vec3 col;
    switch (mode) {
        case 0: col = colorA(n); break;
        case 1: col = colorB(n); break;
        case 2: col = colorC(n); break;
        default: col = vec3(n); break;
    }

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

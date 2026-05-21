#version 310 es
precision highp float;
out vec4 fragColor;

float noise3(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

float fbm3(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        val += amp * noise3(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float n = fbm3(uv * 3.0);
    vec3 col = mix(vec3(0.1, 0.2, 0.4), vec3(0.8, 0.6, 0.3), n);
    fragColor = vec4(col, 1.0);
}

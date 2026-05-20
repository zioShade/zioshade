#version 310 es
precision highp float;
out vec4 fragColor;

float wave(vec2 uv, float freq, float amp, float phase) {
    return sin(uv.x * freq + phase) * amp;
}

void main() {
    vec2 uv = gl_FragCoord.xy * 0.02;
    float y = 0.0;
    for (int i = 1; i <= 5; i++) {
        float fi = float(i);
        y += wave(uv, fi * 2.0, 0.5 / fi, fi * 1.3);
    }
    float d = abs(uv.y - y);
    float line = smoothstep(0.1, 0.0, d);
    vec3 col = mix(vec3(0.1, 0.2, 0.4), vec3(0.3, 0.7, 1.0), line);
    fragColor = vec4(col, 1.0);
}

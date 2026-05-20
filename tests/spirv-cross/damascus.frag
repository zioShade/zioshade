#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Damascus steel pattern
    float layers = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float freq = 10.0 + fi * 5.0;
        float phase = fi * 1.7;
        layers += sin(uv.x * freq + phase + sin(uv.y * (3.0 + fi)) * 2.0);
    }
    float pattern = layers * 0.1 + 0.5;
    vec3 dark = vec3(0.15, 0.15, 0.18);
    vec3 light = vec3(0.5, 0.48, 0.52);
    vec3 col = mix(dark, light, pattern);
    fragColor = vec4(col, 1.0);
}

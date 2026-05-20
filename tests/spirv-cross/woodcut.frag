#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Woodcut / relief print effect
    float val = sin(uv.x * 3.0 + sin(uv.y * 2.0) * 2.0) * cos(uv.y * 4.0) * 0.5 + 0.5;
    // Threshold for woodcut effect
    float threshold = 0.45 + 0.1 * sin(uv.x * 0.5 + uv.y * 0.7);
    float cut = step(threshold, val);
    // Hatching in dark areas
    float hatch = sin((uv.x + uv.y) * 40.0) * 0.5 + 0.5;
    vec3 paper = vec3(0.95, 0.92, 0.85);
    vec3 ink = vec3(0.1, 0.08, 0.05);
    vec3 col = mix(paper, ink, cut * hatch);
    fragColor = vec4(col, 1.0);
}

#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.02;
    // Stained glass window
    vec2 cell = floor(uv);
    vec2 f = fract(uv);
    float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    float border = smoothstep(0.06, 0.03, edge);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
    vec3 glass = vec3(0.3) + 0.6 * cos(6.28 * (h + vec3(0.0, 0.33, 0.67)));
    glass *= 0.6 + 0.4 * (1.0 - border);
    vec3 col = mix(glass, vec3(0.05), border);
    fragColor = vec4(col, 1.0);
}

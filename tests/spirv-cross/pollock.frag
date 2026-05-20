#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Abstract expressionist (Pollock-inspired)
    vec3 col = vec3(0.95, 0.93, 0.88); // canvas
    // Paint splashes
    for (int i = 0; i < 15; i++) {
        float fi = float(i);
        vec2 center = vec2(
            fract(sin(fi * 127.1) * 43758.5) * 12.0 + 1.0,
            fract(sin(fi * 311.7) * 43758.5) * 12.0 + 1.0
        );
        float d = length(uv - center);
        float size = 0.3 + fract(sin(fi * 74.3) * 43758.5) * 1.0;
        float splash = smoothstep(size, size * 0.7, d);
        vec3 paint = vec3(
            fract(sin(fi * 13.7) * 43758.5),
            fract(sin(fi * 51.3) * 43758.5),
            fract(sin(fi * 93.1) * 43758.5)
        );
        col = mix(col, paint, splash);
    }
    fragColor = vec4(col, 1.0);
}

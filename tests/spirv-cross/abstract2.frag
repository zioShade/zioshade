#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Abstract expressionism with palette
    vec3 col = vec3(0.95, 0.92, 0.88); // canvas
    // Paint layers
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        vec2 center = vec2(
            sin(fi * 2.17 + 0.5) * 0.6,
            cos(fi * 1.73 + 1.2) * 0.6
        );
        float d = length(uv - center);
        float size = 0.15 + 0.15 * fract(sin(fi * 74.3) * 43758.5);
        float splash = smoothstep(size, size * 0.6, d);
        vec3 paint = vec3(
            sin(fi * 2.1) * 0.5 + 0.5,
            sin(fi * 3.7 + 1.0) * 0.5 + 0.5,
            sin(fi * 5.3 + 2.0) * 0.5 + 0.5
        );
        col = mix(col, paint, splash);
    }
    fragColor = vec4(col, 1.0);
}

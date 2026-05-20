#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Aquarium / underwater scene
    vec3 col = vec3(0.05, 0.15, 0.3);
    // Caustic light patterns
    float c1 = sin(uv.x * 3.0 + sin(uv.y * 2.0) * 2.0);
    float c2 = cos(uv.y * 4.0 + sin(uv.x * 3.0) * 1.5);
    float caustic = (c1 + c2) * 0.25 + 0.5;
    caustic = pow(caustic, 3.0);
    col += vec3(0.1, 0.2, 0.3) * caustic;
    // Bubbles
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        vec2 bpos = vec2(
            fract(sin(fi * 127.1) * 43758.5) * 12.0 + 1.0,
            fract(sin(fi * 311.7 + 0.5) * 43758.5) * 10.0
        );
        float d = length(uv - bpos);
        float size = 0.2 + fract(sin(fi * 74.3) * 43758.5) * 0.4;
        float bubble = smoothstep(size, size - 0.02, d) * (1.0 - smoothstep(size - 0.08, size - 0.06, d));
        float highlight = smoothstep(0.05, 0.02, length(uv - bpos - vec2(size * 0.3, size * 0.3)));
        col += vec3(0.3, 0.5, 0.7) * bubble * 0.3;
        col += vec3(0.8) * highlight * 0.3;
    }
    fragColor = vec4(col, 1.0);
}

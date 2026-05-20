#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Sierpinski carpet (2D)
    float scale = 3.0;
    vec2 p = uv * scale;
    float hole = 0.0;
    for (int i = 0; i < 4; i++) {
        vec2 f = fract(p);
        float cx = step(1.0/3.0, f.x) * step(f.x, 2.0/3.0);
        float cy = step(1.0/3.0, f.y) * step(f.y, 2.0/3.0);
        hole = max(hole, cx * cy);
        p *= 3.0;
    }
    float carpet = 1.0 - hole;
    vec3 col = vec3(0.1, 0.15, 0.3) + vec3(0.7, 0.5, 0.2) * carpet;
    col *= smoothstep(1.5, 1.0, length(uv));
    fragColor = vec4(col, 1.0);
}

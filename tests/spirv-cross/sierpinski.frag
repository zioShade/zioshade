#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Recursive Sierpinski triangle approximation
    float d = 1.0;
    vec2 p = uv;
    for (int i = 0; i < 5; i++) {
        p = fract(p * 2.0);
        float edge = min(min(p.x, p.y), 1.0 - p.x - p.y);
        d = min(d, edge);
    }
    float tri = smoothstep(0.02, 0.0, d);
    vec3 col = mix(vec3(0.1), vec3(0.3, 0.7, 0.4), tri);
    fragColor = vec4(col, 1.0);
}

#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Reaction-diffusion approximation
    float cell = 8.0;
    vec2 id = floor(uv * cell);
    vec2 gv = fract(uv * cell) - 0.5;
    float n = fract(sin(dot(id, vec2(12.9898, 78.233))) * 43758.5453);
    float size = n * 0.3 + 0.1;
    float d = length(gv) - size;
    // Check neighbors for closest
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue;
            vec2 offset = vec2(float(x), float(y));
            vec2 nid = id + offset;
            float nn = fract(sin(dot(nid, vec2(12.9898, 78.233))) * 43758.5453);
            float nd = length(gv - offset + vec2(nn * 0.4) - 0.2) - (nn * 0.3 + 0.1);
            d = min(d, nd);
        }
    }
    float edge = smoothstep(0.02, -0.02, d);
    vec3 col = mix(vec3(0.1), vec3(0.8, 0.6, 0.3), edge);
    fragColor = vec4(col, 1.0);
}

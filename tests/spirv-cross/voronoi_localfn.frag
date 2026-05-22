#version 310 es
precision highp float;
out vec4 fragColor;

float hash2(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float voronoi(vec2 p) {
    float minDist = 1.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 neighbor = vec2(float(i), float(j));
            vec2 cell = floor(p) + neighbor;
            vec2 point = vec2(hash2(cell), hash2(cell + vec2(37.0, 59.0)));
            float d = length(neighbor + point - fract(p));
            if (d < minDist) minDist = d;
        }
    }
    return minDist;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;
    float v = voronoi(uv * 5.0);
    vec3 col = vec3(v);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

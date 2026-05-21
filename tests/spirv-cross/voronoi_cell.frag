#version 310 es
precision highp float;
out vec4 fragColor;

float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5); }

vec2 voronoi2(vec2 p) {
    vec2 n = floor(p);
    vec2 f = fract(p);
    float md = 8.0;
    vec2 mr = vec2(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 g = vec2(float(i), float(j));
            vec2 o = vec2(hash2(n + g), hash2(n + g + 0.5));
            vec2 r = g + o - f;
            float d = dot(r, r);
            if (d < md) { md = d; mr = r; }
        }
    }
    return mr;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec2 v = voronoi2(uv * 4.0);
    float d = length(v);
    vec3 col = vec3(0.5 + 0.5 * cos(d * 6.0 + vec3(0.0, 1.0, 2.0)));
    fragColor = vec4(col, 1.0);
}

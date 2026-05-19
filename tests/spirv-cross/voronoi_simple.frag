#version 450
layout(location = 0) out vec4 FragColor;
vec2 hash2(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 4.0;
    vec2 i = floor(uv);
    vec2 f = fract(uv);
    float md = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 nb = vec2(float(x), float(y));
            vec2 pt = hash2(i + nb);
            float d = length(nb + pt - f);
            md = min(md, d);
        }
    }
    vec3 col = vec3(md * 0.8);
    FragColor = vec4(col, 1.0);
}

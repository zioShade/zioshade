#version 310 es
precision highp float;
out vec4 fragColor;

// Test: nested function calls — function calling function
float hash3(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

float voronoi2(vec2 uv) {
    vec2 cell = floor(uv);
    vec2 f = fract(uv);
    float min_d = 1.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 point = vec2(hash3(cell + neighbor), hash3(cell + neighbor + vec2(37.0, 59.0)));
            float d = length(neighbor + point - f);
            min_d = min(min_d, d);
        }
    }
    return min_d;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float v = voronoi2(uv * 5.0);
    vec3 col = vec3(0.1) + vec3(0.7, 0.5, 0.3) * smoothstep(0.3, 0.0, v);
    fragColor = vec4(col, 1.0);
}

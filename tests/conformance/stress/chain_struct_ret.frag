// Tests: multiple functions forming a call chain with struct returns
precision mediump float;
uniform vec2 u_resolution;

struct Vec2Pair { vec2 a; vec2 b; };

Vec2Pair split(vec2 v) {
    Vec2Pair p;
    p.a = vec2(v.x, 0.0);
    p.b = vec2(0.0, v.y);
    return p;
}

float process(vec2 v) {
    Vec2Pair p = split(v);
    return length(p.a) + length(p.b);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float v = process(uv);
    gl_FragColor = vec4(vec3(fract(v)), 1.0);
}

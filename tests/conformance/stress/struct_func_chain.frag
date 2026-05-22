// Tests: multiple struct-return functions calling each other
precision mediump float;
uniform vec2 u_resolution;

struct Vec2Pair {
    vec2 a;
    vec2 b;
};

Vec2Pair splitVec2(vec2 v) {
    Vec2Pair p;
    p.a = vec2(v.x, 0.0);
    p.b = vec2(0.0, v.y);
    return p;
}

vec2 process(vec2 v) {
    Vec2Pair p = splitVec2(v);
    return p.a * 2.0 + p.b * 3.0;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec2 result = process(uv);
    
    vec3 col = vec3(result.x, result.y, length(result));
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

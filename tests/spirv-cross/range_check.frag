#version 450

// Test: nested struct comparison
struct Range {
    float low;
    float high;
};

bool inRange(float x, Range r) {
    return x >= r.low && x <= r.high;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    Range r1;
    r1.low = 0.2;
    r1.high = 0.8;

    Range r2;
    r2.low = 0.3;
    r2.high = 0.7;

    bool inside = inRange(uv.x, r1) && inRange(uv.y, r2);
    vec3 col = inside ? vec3(0.8, 0.4, 0.2) : vec3(0.1, 0.1, 0.15);

    gl_FragColor = vec4(col, 1.0);
}

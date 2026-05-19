#version 450

// Test: bvec from comparison, then any/all
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 threshold = vec2(0.3, 0.7);

    bvec2 test1 = greaterThan(uv, threshold);
    bvec2 test2 = lessThan(uv, threshold);
    bvec2 test3 = equal(uv, threshold);

    float a = any(test1) ? 1.0 : 0.0;
    float b = all(test2) ? 1.0 : 0.0;
    float c = float(test3.x || test3.y);

    gl_FragColor = vec4(a, b, c, 1.0);
}

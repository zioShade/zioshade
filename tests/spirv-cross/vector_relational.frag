#version 450

// Test vector relational functions: lessThan, greaterThan, equal, etc.
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 a = uv;
    vec2 b = vec2(0.5);

    bvec2 lt = lessThan(a, b);
    bvec2 gt = greaterThan(a, b);
    bvec2 eq = equal(a, b);
    bvec2 le = lessThanEqual(a, b);
    bvec2 ge = greaterThanEqual(a, b);

    float r = all(lt) ? 1.0 : 0.5;
    float g = any(gt) ? 1.0 : 0.3;
    float bl = all(le) ? 0.8 : 0.2;

    gl_FragColor = vec4(r, g, bl, 1.0);
}

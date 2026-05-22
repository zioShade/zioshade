// Tests: vector relational functions (lessThan, greaterThan, equal, not)
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec2 a = uv;
    vec2 b = vec2(0.5, 0.5);
    
    // Vector comparisons return bvec
    bvec2 lt = lessThan(a, b);
    bvec2 gt = greaterThan(a, b);
    bvec2 eq = equal(a, b);
    bvec2 le = lessThanEqual(a, b);
    bvec2 ge = greaterThanEqual(a, b);
    bvec2 ne = notEqual(a, b);
    
    // any/all on bvec
    float any_lt = any(lt) ? 1.0 : 0.0;
    float all_gt = all(gt) ? 1.0 : 0.0;
    
    // not on bvec
    bvec2 not_lt = not(lt);
    float any_not = any(not_lt) ? 1.0 : 0.0;
    
    // Use results
    float r = any_lt * 0.3 + all_gt * 0.2;
    float g = float(le.x) * 0.4 + float(ge.y) * 0.3;
    float b_val = float(ne.x) * 0.5 + any_not * 0.2;
    
    gl_FragColor = vec4(r, g, b_val, 1.0);
}

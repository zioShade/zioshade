// Tests: struct function parameter and return value in complex expression
precision mediump float;
uniform vec2 u_resolution;

struct Range {
    float min_val;
    float max_val;
};

Range makeRange(float center, float width) {
    Range r;
    r.min_val = center - width * 0.5;
    r.max_val = center + width * 0.5;
    return r;
}

float mapRange(float val, Range from, Range to) {
    float t = (val - from.min_val) / (from.max_val - from.min_val + 0.001);
    return to.min_val + t * (to.max_val - to.min_val);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Range src = makeRange(0.5, 1.0);
    Range dst = makeRange(0.0, 2.0);
    
    float mapped = mapRange(uv.x, src, dst);
    float r = fract(mapped);
    float g = fract(mapRange(uv.y, src, dst));
    
    gl_FragColor = vec4(r, g, 0.5, 1.0);
}

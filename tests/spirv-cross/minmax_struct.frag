#version 450

// Test: multiple return values via struct pattern
struct MinMax {
    float minVal;
    float maxVal;
};

MinMax findMinMax(float a, float b, float c, float d) {
    MinMax result;
    result.minVal = min(min(a, b), min(c, d));
    result.maxVal = max(max(a, b), max(c, d));
    return result;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = uv.x;
    float b = uv.y;
    float c = 1.0 - uv.x;
    float d = 1.0 - uv.y;

    MinMax mm = findMinMax(a, b, c, d);
    float range = mm.maxVal - mm.minVal;

    gl_FragColor = vec4(mm.minVal, mm.maxVal, range, 1.0);
}

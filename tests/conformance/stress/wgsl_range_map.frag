// Test: multiple function returns with struct
#version 450

layout(location = 0) out vec4 fragColor;

struct Range {
    float min;
    float max;
};

Range computeRange(float center, float radius) {
    Range r;
    r.min = center - radius;
    r.max = center + radius;
    return r;
}

float mapToRange(float val, Range from, Range to) {
    float t = (val - from.min) / (from.max - from.min);
    return to.min + t * (to.max - to.min);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    Range src = computeRange(0.5, 0.5);
    Range dst = computeRange(uv.x, 0.3);
    
    float mapped = mapToRange(uv.y, src, dst);
    float clamped = clamp(mapped, dst.min, dst.max);
    
    fragColor = vec4(clamped, mapped, 0.0, 1.0);
}

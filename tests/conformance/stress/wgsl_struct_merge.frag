// Tests: struct equality and field-wise operations
#version 450
layout(location = 0) out vec4 fragColor;

struct Range { float min_val; float max_val; };

Range merge(Range a, Range b) {
    Range r;
    r.min_val = min(a.min_val, b.min_val);
    r.max_val = max(a.max_val, b.max_val);
    return r;
}

void main() {
    Range r1;
    r1.min_val = 0.2;
    r1.max_val = 0.8;
    Range r2;
    r2.min_val = 0.5;
    r2.max_val = 0.9;
    Range combined = merge(r1, r2);
    float span = combined.max_val - combined.min_val;
    fragColor = vec4(vec3(span), 1.0);
}

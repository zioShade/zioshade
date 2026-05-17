#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Octahedral mapping
vec2 octahedralWrap(vec2 p) {
    vec2 absp = abs(p);
    float d = 2.0 - (absp.x + absp.y);
    if (d < 0.0) {
        if (absp.x > absp.y) {
            p.x = sign(p.x) * (2.0 - absp.x);
        } else {
            p.y = sign(p.y) * (2.0 - absp.y);
        }
    }
    return p * 0.5 + 0.5;
}

void main() {
    vec2 p = uv * 2.0 - 1.0;
    vec2 mapped = octahedralWrap(p);
    
    float checker = step(0.5, fract(mapped.x * 10.0)) * step(0.5, fract(mapped.y * 10.0));
    checker = checker * 0.5 + 0.3;
    
    fragColor = vec4(checker * mapped.x, checker * mapped.y, checker, 1.0);
}

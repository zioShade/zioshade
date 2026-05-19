#version 450

// Test: 2D SDF operations
float sdCircle(vec2 p, float r) {
    return length(p) - r;
}

float sdBox2D(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sdfUnion(float a, float b) { return min(a, b); }
float sdfIntersect(float a, float b) { return max(a, b); }
float sdfSubtract(float a, float b) { return max(a, -b); }

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;

    float circle = sdCircle(uv - vec2(-0.3, 0.0), 0.4);
    float box = sdBox2D(uv - vec2(0.3, 0.0), vec2(0.3));
    float combined = sdfUnion(circle, box);

    vec3 col = combined > 0.0 ? vec3(0.1) : vec3(0.8, 0.4, 0.2);
    col += 0.01 / (abs(combined) + 0.01) * vec3(0.3);

    gl_FragColor = vec4(col, 1.0);
}

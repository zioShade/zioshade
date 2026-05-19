#version 450

// Test: face-centered cubic lattice SDF pattern
float sdSphere(vec3 p, float r) {
    return length(p) - r;
}

float sdBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 p = vec3(uv * 4.0 - 2.0, 0.0);

    float d1 = sdSphere(p, 0.5);
    float d2 = sdBox(p - vec3(1.0, 0.5, 0.0), vec3(0.3));

    float d = min(d1, d2);
    vec3 col = d > 0.0 ? vec3(0.1, 0.2, 0.3) : vec3(0.8, 0.6, 0.2);
    col += 0.02 / (abs(d) + 0.02) * vec3(0.5);

    gl_FragColor = vec4(col, 1.0);
}

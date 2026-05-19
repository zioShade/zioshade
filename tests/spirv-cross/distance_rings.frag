#version 450

// Test: distance-based procedural pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float d1 = distance(uv, vec2(0.3, 0.3));
    float d2 = distance(uv, vec2(0.7, 0.7));
    float d3 = distance(uv, vec2(0.5, 0.5));

    float ring1 = abs(sin(d1 * 30.0));
    float ring2 = abs(sin(d2 * 30.0));
    float ring3 = abs(sin(d3 * 30.0));

    float pattern = min(ring1, min(ring2, ring3));
    vec3 col = vec3(pattern, pattern * 0.8, pattern * 0.6);

    gl_FragColor = vec4(col, 1.0);
}

#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d = length(uv - 0.5);
    float ring1 = smoothstep(0.08, 0.1, d) - smoothstep(0.1, 0.12, d);
    float ring2 = smoothstep(0.18, 0.2, d) - smoothstep(0.2, 0.22, d);
    float ring3 = smoothstep(0.28, 0.3, d) - smoothstep(0.3, 0.32, d);
    float bull = 1.0 - smoothstep(0.03, 0.05, d);
    float mask = max(max(ring1, ring2), max(ring3, bull));
    vec3 col = mix(vec3(0.9, 0.9, 0.8), vec3(0.9, 0.1, 0.1), mask);
    gl_FragColor = vec4(col, 1.0);
}

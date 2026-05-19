#version 450
// Test: simple shadow via step
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float circle = step(length(uv - vec2(0.35, 0.5)), 0.2);
    float shadow = step(length(uv - vec2(0.38, 0.47)), 0.2);
    float lit = circle * (1.0 - shadow * 0.5);
    vec3 col = mix(vec3(0.9), vec3(0.3, 0.4, 0.6), lit);
    gl_FragColor = vec4(col, 1.0);
}

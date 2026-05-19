#version 450
// Test: cross dissolve between patterns
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 a = vec3(1.0, 0.5, 0.2) * smoothstep(0.3, 0.7, uv.x);
    vec3 b = vec3(0.2, 0.5, 1.0) * smoothstep(0.3, 0.7, uv.y);
    vec3 col = mix(a, b, 0.5);
    gl_FragColor = vec4(col, 1.0);
}

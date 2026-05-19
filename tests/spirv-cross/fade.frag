#version 450
// Test: distance-based fade
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d = distance(uv, vec2(0.5));
    float fade = 1.0 - smoothstep(0.0, 0.7, d);
    vec3 col = vec3(0.8, 0.5, 0.3) * fade;
    gl_FragColor = vec4(col, 1.0);
}

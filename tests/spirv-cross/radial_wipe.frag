#version 450
// Test: radial wipe transition
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float angle = atan(p.y, p.x) / 6.28 + 0.5;
    vec3 a = vec3(0.8, 0.3, 0.1);
    vec3 b = vec3(0.1, 0.3, 0.8);
    vec3 col = angle < uv.x ? a : b;
    gl_FragColor = vec4(col, 1.0);
}

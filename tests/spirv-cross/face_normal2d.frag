#version 450
// Test: 2D normal from gradient
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float h = sin(uv.x * 6.28) * cos(uv.y * 6.28);
    vec2 grad = vec2(dFdx(h), dFdy(h));
    vec2 n = normalize(grad);
    gl_FragColor = vec4(n * 0.5 + 0.5, 0.5, 1.0);
}

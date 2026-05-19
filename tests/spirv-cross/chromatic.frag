#version 450
// Test: chromatic aberration
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 dir = uv - 0.5;
    float r = length(uv + dir * 0.02 - 0.5);
    float g = length(uv - 0.5);
    float b = length(uv - dir * 0.02 - 0.5);
    gl_FragColor = vec4(1.0 - r, 1.0 - g, 1.0 - b, 1.0);
}

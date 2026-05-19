#version 450
// Test: glow effect around center
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d = length(uv - 0.5);
    float glow = exp(-d * 5.0);
    vec3 col = vec3(0.9, 0.7, 0.3) * glow + vec3(0.05, 0.05, 0.1);
    gl_FragColor = vec4(col, 1.0);
}

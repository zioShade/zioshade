#version 450
// Test: 2D wave pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float wave = sin(uv.x * 20.0 + uv.y * 10.0) * cos(uv.y * 15.0 - uv.x * 5.0);
    vec3 col = vec3(wave * 0.5 + 0.5);
    gl_FragColor = vec4(col, 1.0);
}

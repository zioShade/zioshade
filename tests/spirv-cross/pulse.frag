#version 450
// Test: pulsing effect via sin composition
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float pulse = sin(uv.x * 10.0) * sin(uv.y * 10.0);
    pulse = pulse * 0.5 + 0.5;
    vec3 col = vec3(pulse, pulse * uv.x, pulse * uv.y);
    gl_FragColor = vec4(col, 1.0);
}

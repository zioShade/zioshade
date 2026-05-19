#version 450
// Test: posterization
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = vec3(uv, 0.5);
    float levels = 4.0;
    col = floor(col * levels + 0.5) / levels;
    gl_FragColor = vec4(col, 1.0);
}

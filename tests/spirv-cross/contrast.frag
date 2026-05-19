#version 450
// Test: contrast adjustment
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = vec3(uv, 0.5);
    float contrast = uv.x * 2.0;
    col = (col - 0.5) * contrast + 0.5;
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}

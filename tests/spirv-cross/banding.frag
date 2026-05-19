#version 450
// Test: color banding
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = floor(uv.x * 8.0) / 8.0;
    float y = floor(uv.y * 8.0) / 8.0;
    vec3 col = vec3(x, y, (x + y) * 0.5);
    gl_FragColor = vec4(col, 1.0);
}

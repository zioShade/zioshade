#version 450
// Test: nested clamp/min/max
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x * 3.0 - 1.0;
    float y = uv.y * 3.0 - 1.0;
    float a = clamp(min(x, y), 0.0, 1.0);
    float b = clamp(max(x, y), 0.0, 1.0);
    float c = min(clamp(x, 0.0, 1.0), clamp(y, 0.0, 1.0));
    gl_FragColor = vec4(a, b, c, 1.0);
}

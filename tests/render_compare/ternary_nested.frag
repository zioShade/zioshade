#version 430
layout(location = 0) out vec4 FragColor;

// Test: ternary with complex conditions
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;
    float a = (x > 0.5) ? (y > 0.5 ? 1.0 : 0.5) : (y > 0.5 ? 0.3 : 0.0);
    float b = (x + y > 1.0) ? x : y;
    FragColor = vec4(a, b, (a + b) * 0.5, 1.0);
}

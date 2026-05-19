#version 430
layout(location = 0) out vec4 FragColor;

// Test: concentric squares
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    vec2 p = abs(uv);
    float d = max(p.x, p.y);
    float rings = fract(d * 8.0);
    float col = step(0.5, rings);
    FragColor = vec4(col, col * 0.7, col * 0.3, 1.0);
}

#version 430
layout(location = 0) out vec4 FragColor;

// Test: smoothstep-based gradient
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float r = smoothstep(0.0, 1.0, uv.x);
    float g = smoothstep(0.2, 0.8, uv.y);
    float b = smoothstep(0.3, 0.7, (uv.x + uv.y) * 0.5);
    FragColor = vec4(r, g, b, 1.0);
}

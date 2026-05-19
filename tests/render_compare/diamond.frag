#version 430
layout(location = 0) out vec4 FragColor;

// Test: diamond pattern via abs + mod
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 4.0;
    vec2 p = abs(mod(uv, 1.0) - 0.5);
    float d = p.x + p.y;
    float pattern = smoothstep(0.45, 0.5, d);
    FragColor = vec4(pattern, pattern * 0.8, pattern * 0.6, 1.0);
}

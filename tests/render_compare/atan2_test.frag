#version 430
layout(location = 0) out vec4 FragColor;

// Test atan2 via atan(y,x)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    vec2 p = uv * 2.0 - 1.0;
    float a = atan(p.y, p.x);
    float r = a / 6.2832 + 0.5;
    float d = length(p);
    FragColor = vec4(r, d, sin(a * 3.0) * 0.5 + 0.5, 1.0);
}

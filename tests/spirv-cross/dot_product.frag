#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 a = uv - 0.5;
    vec2 b = vec2(0.707, 0.707);
    float d = dot(a, b);
    float cross_val = a.x * b.y - a.y * b.x;
    FragColor = vec4(d * 0.5 + 0.5, cross_val * 0.5 + 0.5, length(a), 1.0);
}

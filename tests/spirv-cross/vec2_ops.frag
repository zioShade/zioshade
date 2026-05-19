#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 a = vec2(uv.x, uv.y);
    vec2 b = vec2(uv.y, uv.x);
    vec2 sum = a + b;
    vec2 diff = a - b;
    FragColor = vec4(sum * 0.5, abs(diff) * 0.5 + 0.5);
}

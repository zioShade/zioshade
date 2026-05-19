#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float angle = uv.x * 6.28318;
    float s = sin(angle) * 0.5 + 0.5;
    float c = cos(angle) * 0.5 + 0.5;
    FragColor = vec4(s, c, abs(sin(angle * 2.0)) * 0.5, 1.0);
}

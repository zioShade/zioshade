#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float v = (uv.x - 0.5) * 2.0;
    float a = abs(v);
    float s = sign(v) * 0.5 + 0.5;
    FragColor = vec4(a, s, v * 0.5 + 0.5, 1.0);
}

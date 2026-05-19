#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float angle = atan(uv.y, uv.x);
    float r = length(uv);
    float h = angle / 6.28318 + 0.5;
    FragColor = vec4(h, r, smoothstep(0.3, 0.7, r), 1.0);
}

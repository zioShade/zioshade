#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = mod(uv.x * 10.0, 3.0) / 3.0;
    float b = uv.x / (uv.y + 0.001);
    float c = floor(uv.x * 4.0) / 4.0;
    FragColor = vec4(a, clamp(b, 0.0, 1.0), c, 1.0);
}

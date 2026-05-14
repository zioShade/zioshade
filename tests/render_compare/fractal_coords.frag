#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / 128.0;
    float r = fract(uv.x * 4.0);
    float g = fract(uv.y * 4.0);
    float b = fract((uv.x + uv.y) * 2.0);
    FragColor = vec4(r, g, b, 1.0);
}

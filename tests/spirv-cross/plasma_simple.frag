#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float v = sin(uv.x * 10.0) + sin(uv.y * 10.0) + sin((uv.x + uv.y) * 10.0);
    v = v / 3.0 * 0.5 + 0.5;
    vec3 col = vec3(sin(v * 6.28) * 0.5 + 0.5, sin(v * 6.28 + 2.09) * 0.5 + 0.5, sin(v * 6.28 + 4.19) * 0.5 + 0.5);
    FragColor = vec4(col, 1.0);
}

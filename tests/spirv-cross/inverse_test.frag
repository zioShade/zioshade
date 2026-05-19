#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    mat2 m = mat2(2.0, 1.0, 1.0, 2.0);
    mat2 inv = inverse(m);
    vec2 v = inv * uv;
    FragColor = vec4(abs(v.x), abs(v.y), 0.0, 1.0);
}

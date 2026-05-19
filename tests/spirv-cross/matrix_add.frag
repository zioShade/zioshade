#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    mat2 m = mat2(uv.x, uv.y, 1.0 - uv.x, 1.0 - uv.y);
    mat2 n = m + mat2(1.0);
    mat2 d = m - mat2(0.5);
    vec2 v = (n - d) * vec2(1.0);
    FragColor = vec4(v.x, v.y, 0.5, 1.0);
}

#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    mat2 a = mat2(uv.x, uv.y, 1.0 - uv.x, 1.0 - uv.y);
    mat2 b = mat2(1.0 - uv.x, 1.0 - uv.y, uv.x, uv.y);
    mat2 c = a * 0.5 + b * 0.5;
    vec2 v = c * vec2(1.0, 1.0);
    FragColor = vec4(v.x, v.y, 0.5, 1.0);
}

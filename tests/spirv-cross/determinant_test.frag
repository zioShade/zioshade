#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    mat2 m = mat2(uv.x, uv.y, -uv.y, uv.x);
    float d = determinant(m);
    FragColor = vec4(abs(d) * 0.5, sign(d) * 0.5 + 0.5, 0.0, 1.0);
}

#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    mat2 m = mat2(uv.x, uv.y, 1.0 - uv.x, 1.0 - uv.y);
    mat2 t = transpose(m);
    vec2 v = t * vec2(1.0, 0.0);
    FragColor = vec4(v, 1.0 - v.x, 1.0);
}

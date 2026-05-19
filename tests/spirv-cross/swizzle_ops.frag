#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec4 v = vec4(uv.x, uv.y, 1.0 - uv.x, 1.0 - uv.y);
    v.xz = v.yw;
    FragColor = v;
}

#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    mat4 m = mat4(1.0);
    vec4 v = m * vec4(uv, 0.0, 1.0);
    FragColor = vec4(v.xy, 0.0, 1.0);
}

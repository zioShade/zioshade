#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec4 uv = vec4(gl_FragCoord.xy / vec2(128.0), 0.5, 1.0);
    mat4 a = mat4(1.0);
    mat4 b = mat4(uv.x);
    mat4 c = a - b;
    vec4 v = c * vec4(1.0);
    FragColor = vec4(v);
}

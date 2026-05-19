#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    vec3 a = vec3(uv, 0.5);
    vec3 b = vec3(0.5, uv);
    vec3 c = cross(a, b);
    FragColor = vec4(c * 0.5 + 0.5, 1.0);
}

#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 n = vec3(uv - 0.5, 0.5);
    vec3 i = vec3(0.0, 0.0, -1.0);
    vec3 nref = vec3(0.0, 0.0, 1.0);
    vec3 ff = faceforward(n, i, nref);
    FragColor = vec4(ff * 0.5 + 0.5, 1.0);
}

#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec3 uv = vec3(gl_FragCoord.xy / vec2(128.0), 0.5);
    mat3 a = mat3(1.0);
    mat3 b = mat3(uv.x, 0.0, 0.0, 0.0, uv.y, 0.0, 0.0, 0.0, uv.z);
    mat3 c = a + b;
    vec3 v = c * vec3(1.0);
    FragColor = vec4(v, 1.0);
}

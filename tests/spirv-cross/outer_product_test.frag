#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 a = vec3(uv.x, uv.y, 0.5);
    vec3 b = vec3(1.0, 0.5, uv.x);
    mat3 m = outerProduct(a, b);
    vec3 result = m * vec3(1.0, 1.0, 1.0);
    FragColor = vec4(result * 0.33, 1.0);
}

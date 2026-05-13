
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    vec3 a = vec3(uv, 0.5);
    vec3 b = vec3(0.3, uv.x, uv.y);
    vec3 c = a * b + vec3(0.1);
    c = normalize(c) * 0.5 + 0.5;
    FragColor = vec4(c, 1.0);
}

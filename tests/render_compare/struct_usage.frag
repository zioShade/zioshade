
#version 430
layout(location = 0) out vec4 FragColor;
struct Light {
    vec3 color;
    float intensity;
};
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    Light l;
    l.color = vec3(uv, 0.5);
    l.intensity = 2.0;
    vec3 col = l.color * l.intensity * 0.5;
    FragColor = vec4(col, 1.0);
}

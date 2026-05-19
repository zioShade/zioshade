#version 450
layout(location = 0) out vec4 FragColor;
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float n = hash(floor(uv * 8.0));
    FragColor = vec4(vec3(n), 1.0);
}

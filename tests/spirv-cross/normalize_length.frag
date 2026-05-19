#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float len = length(uv);
    vec2 n = normalize(uv + vec2(0.001));
    float dist = distance(uv, vec2(0.0));
    FragColor = vec4(n * 0.5 + 0.5, smoothstep(0.3, 0.8, dist), 1.0);
}

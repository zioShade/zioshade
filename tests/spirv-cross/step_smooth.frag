#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float s1 = step(0.3, uv.x);
    float s2 = step(0.5, uv.x);
    float sm = smoothstep(0.2, 0.8, uv.y);
    FragColor = vec4(s1 * sm, s2 * sm, (1.0 - s1) * sm, 1.0);
}

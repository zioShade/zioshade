#version 450
layout(location = 0) out vec4 FragColor;
float sdBox(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float d = sdBox(uv, vec2(0.4, 0.3));
    float fill = 1.0 - smoothstep(-0.01, 0.01, d);
    FragColor = vec4(vec3(0.2 + 0.6 * fill), 1.0);
}

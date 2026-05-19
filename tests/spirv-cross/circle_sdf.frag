#version 450
layout(location = 0) out vec4 FragColor;
float sdCircle(vec2 p, float r) { return length(p) - r; }
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float d = sdCircle(uv, 0.5);
    float fill = 1.0 - smoothstep(-0.01, 0.01, d);
    float outline = smoothstep(0.02, 0.0, abs(d) - 0.02);
    vec3 col = vec3(0.2) + vec3(0.8, 0.3, 0.1) * fill + vec3(0.1) * outline;
    FragColor = vec4(col, 1.0);
}

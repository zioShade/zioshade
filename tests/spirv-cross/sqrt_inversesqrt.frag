#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float s = sqrt(uv.x);
    float is = inversesqrt(uv.x + 0.01) * 0.1;
    FragColor = vec4(s, is, sqrt(uv.y), 1.0);
}

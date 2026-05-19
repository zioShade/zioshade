#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = pow(uv.x, 2.0);
    float b = exp(uv.x * 3.0);
    float c = log(uv.x * 10.0 + 1.0) / 2.0;
    FragColor = vec4(a, b * 0.3, c * 0.4, 1.0);
}

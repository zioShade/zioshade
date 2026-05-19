#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = uv.x;
    float b = uv.y;
    float c = (a + b) * (a - b);
    float d = c / (a * a + b * b + 0.001);
    float e = sqrt(abs(d));
    FragColor = vec4(e, c * 0.5 + 0.5, d * 0.5 + 0.5, 1.0);
}

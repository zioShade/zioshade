#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int x = int(uv.x * 10.0);
    int y = int(uv.y * 10.0) + 1;
    int q = x / y;
    int r = x - q * y;
    float f = float(q) / 10.0 + float(r) / 100.0;
    FragColor = vec4(f, 0.0, 0.0, 1.0);
}

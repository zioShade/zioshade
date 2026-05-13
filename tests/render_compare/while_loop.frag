
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float x = uv.x;
    int n = 0;
    while (x > 0.1 && n < 10) {
        x *= 0.7;
        n++;
    }
    float c = float(n) / 10.0;
    FragColor = vec4(c, x, uv.y, 1.0);
}

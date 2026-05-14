#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float x = uv.x;
    int n = 0;
    // Must use discard to prevent optimizer from eliminating the loop
    for (int i = 0; i < 8; i++) {
        x = x * 0.85 + 0.1;
        n = i;
    }
    float r = fract(x * 3.0);
    float g = float(n) / 8.0;
    FragColor = vec4(r, g, uv.y * 0.5, 1.0);
}

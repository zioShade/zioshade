#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float sum = 0.0;
    for (int i = 0; i < 10; i++) {
        if (i == 3) continue;
        if (i == 7) break;
        sum += float(i) * uv.x;
    }
    FragColor = vec4(sum * 0.1, 0.5, 0.3, 1.0);
}

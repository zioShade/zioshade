
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float sum = 0.0;
    for (int i = 0; i < 8; i++) {
        sum += sin(uv.x * 3.14159 * float(i + 1)) * 0.125;
    }
    FragColor = vec4(sum, sum * 0.5, 1.0 - sum, 1.0);
}


#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float v = 0.0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            v += sin(uv.x * float(i+1) * 3.14) * cos(uv.y * float(j+1) * 3.14);
        }
    }
    v = fract(v * 0.5 + 0.5);
    FragColor = vec4(v, v * 0.7, v * 0.3, 1.0);
}

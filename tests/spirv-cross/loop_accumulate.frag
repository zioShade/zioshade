#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float sum = 0.0;
    for (int i = 0; i < 8; i++) {
        float fi = float(i) / 8.0;
        sum += fi * fi;
    }
    sum = sum / 8.0;
    FragColor = vec4(sum * uv.x, sum * uv.y, sum, 1.0);
}

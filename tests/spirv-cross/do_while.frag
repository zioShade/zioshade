#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float val = uv.x;
    int iter = 0;
    while (val > 0.01 && iter < 10) {
        val = val * val;
        iter++;
    }
    FragColor = vec4(val, float(iter) / 10.0, 0.0, 1.0);
}
